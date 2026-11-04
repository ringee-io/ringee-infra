#!/usr/bin/env bash
# Copy the pinned third-party images (Temporal, PostgreSQL client) into this
# account's mirror/* ECR repositories, every architecture, without pulling them
# locally. Tags are immutable, so an existing tag is skipped.
#
#   AWS_PROFILE=ringee-prod scripts/mirror-images.sh prod
#
# Needs crane (brew install crane) or docker with buildx.
set -euo pipefail

ENV_NAME=${1:?usage: mirror-images.sh <prod|staging>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PAIRS=$(terraform -chdir="$ROOT/envs/$ENV_NAME" output -json stack |
  python3 -c 'import json,sys; [print(src, dst) for src, dst in json.load(sys.stdin)["mirror_images"].items()]')

REGISTRY=$(head -1 <<<"$PAIRS" | awk '{print $2}' | cut -d/ -f1)
REGION=$(cut -d. -f4 <<<"$REGISTRY")
if command -v crane >/dev/null; then
  aws ecr get-login-password --region "$REGION" | crane auth login "$REGISTRY" -u AWS --password-stdin
else
  aws ecr get-login-password --region "$REGION" | docker login "$REGISTRY" -u AWS --password-stdin
fi

while read -r SRC DST; do
  REPO=${DST#*/}; REPO=${REPO%:*}; TAG=${DST##*:}
  if aws ecr describe-images --region "$REGION" --repository-name "$REPO" --image-ids imageTag="$TAG" >/dev/null 2>&1; then
    echo "exists  $DST"
    continue
  fi
  echo "copying $SRC -> $DST"
  if command -v crane >/dev/null; then
    crane copy "$SRC" "$DST"
  else
    docker buildx imagetools create --tag "$DST" "$SRC"
  fi
done <<<"$PAIRS"
