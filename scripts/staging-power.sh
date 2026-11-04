#!/usr/bin/env bash
# Turn staging on or off outside office hours (modules/schedule does it on
# weekdays, 08:00 and 22:00 Santo Domingo).
#
#   AWS_PROFILE=ringee-staging scripts/staging-power.sh on
#   AWS_PROFILE=ringee-staging scripts/staging-power.sh off
set -euo pipefail

ACTION=${1:?usage: staging-power.sh on|off}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUTPUTS=$(terraform -chdir="$ROOT/envs/staging" output -json stack)
out() { python3 -c 'import json,sys; print(eval(sys.argv[1], {"o": json.load(sys.stdin)}))' "$1" <<<"$OUTPUTS"; }

CLUSTER=$(out 'o["cluster_name"]')
DB=$(out 'o["rds_identifier"]')

scale() { # service min max
  aws application-autoscaling register-scalable-target --service-namespace ecs \
    --scalable-dimension ecs:service:DesiredCount --resource-id "service/$CLUSTER/$1" \
    --min-capacity "$2" --max-capacity "$3"
  echo "$1: $2-$3 tasks"
}

case "$ACTION" in
  on)
    aws rds start-db-instance --db-instance-identifier "$DB" >/dev/null 2>&1 || true
    echo "waiting for $DB..."
    aws rds wait db-instance-available --db-instance-identifier "$DB"
    for SERVICE in temporal orchestrator api; do
      KEY=${SERVICE}
      scale "$SERVICE" "$(out "o['service_scale']['$KEY']['min']")" "$(out "o['service_scale']['$KEY']['max']")"
    done
    ;;
  off)
    for SERVICE in api orchestrator temporal; do scale "$SERVICE" 0 0; done
    aws rds stop-db-instance --db-instance-identifier "$DB" >/dev/null 2>&1 || true
    echo "$DB stopping"
    ;;
  *) echo "usage: staging-power.sh on|off" >&2; exit 2 ;;
esac
