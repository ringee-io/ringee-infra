#!/usr/bin/env bash
# Run a one-off task in the cluster and wait for it to finish.
#
#   scripts/run-task.sh <prod|staging> db-bootstrap
#   scripts/run-task.sh <prod|staging> temporal-schema
#   scripts/run-task.sh <prod|staging> temporal-namespace   # after the server is up
#   scripts/run-task.sh <prod|staging> migrate
#   scripts/run-task.sh <prod|staging> ops -- sh -c 'psql "$PG_URL_APP" -c "select 1"'
#
# Uses the AWS session in the environment (AWS_PROFILE) and the outputs of
# envs/<env>. Exits with the container's exit code.
set -euo pipefail

ENV_NAME=${1:?usage: run-task.sh <prod|staging> <task> [-- command...]}
TASK=${2:?usage: run-task.sh <prod|staging> <task> [-- command...]}
shift 2
[[ ${1:-} == "--" ]] && shift

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUTPUTS=$(terraform -chdir="$ROOT/envs/$ENV_NAME" output -json stack)
out() { python3 -c 'import json,sys; print(eval(sys.argv[1], {"o": json.load(sys.stdin)}))' "$1" <<<"$OUTPUTS"; }

CLUSTER=$(out 'o["cluster_name"]')
SUBNETS=$(out '",".join(o["task_subnet_ids"])')
SECURITY_GROUP=$(out 'o["ops_security_group_id"]')

case "$TASK" in
  temporal-schema) CONTAINER=temporal-admin ;;
  temporal-namespace)
    CONTAINER=temporal-admin
    # Retries for up to 3 minutes while the server starts. $TEMPORAL_ADDRESS
    # expands inside the container, not here.
    set -- sh -c 'for attempt in $(seq 1 36); do
        if temporal operator namespace describe --namespace default --address "$TEMPORAL_ADDRESS" >/dev/null 2>&1; then echo "namespace default exists"; exit 0; fi
        temporal operator namespace create --namespace default --retention 72h --address "$TEMPORAL_ADDRESS" && exit 0
        sleep 5
      done
      exit 1'
    ;;
  migrate | db-bootstrap | ops) CONTAINER=$TASK ;;
  *) echo "unknown task: $TASK" >&2; exit 2 ;;
esac
FAMILY=$(out "o['task_families']['$CONTAINER']")

OVERRIDES='{}'
if [[ $# -gt 0 ]]; then
  OVERRIDES=$(python3 -c 'import json,sys; print(json.dumps({"containerOverrides": [{"name": sys.argv[1], "command": sys.argv[2:]}]}))' "$CONTAINER" "$@")
fi

TASK_ARN=$(aws ecs run-task \
  --cluster "$CLUSTER" \
  --task-definition "$FAMILY" \
  --launch-type FARGATE \
  --started-by "run-task.sh" \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUP],assignPublicIp=ENABLED}" \
  --overrides "$OVERRIDES" \
  --query 'tasks[0].taskArn' --output text)
echo "started $TASK_ARN"

aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK_ARN"
EXIT_CODE=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" --query 'tasks[0].containers[0].exitCode' --output text)
REASON=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" --query 'tasks[0].stoppedReason' --output text)

echo "--- logs"
aws logs get-log-events \
  --log-group-name "/ecs/$FAMILY" \
  --log-stream-name "$CONTAINER/$CONTAINER/${TASK_ARN##*/}" \
  --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' || echo "(no logs)"
echo "--- $TASK: exit code $EXIT_CODE ($REASON)"
[[ $EXIT_CODE == "0" ]]
