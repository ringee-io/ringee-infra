#!/usr/bin/env bash
# A tunnel from this Mac to the environment's PostgreSQL, for DBeaver or psql.
#
#   scripts/db-tunnel.sh prod             # localhost:15432
#   scripts/db-tunnel.sh staging          # localhost:15433
#   scripts/db-tunnel.sh <env> password   # copies ringee_editor's password to the clipboard
#
# RDS has no public address. The tunnel goes through Session Manager into a
# small task in the ops security group, which RDS admits, and on to port 5432:
# no SSH, and nothing new listens on the internet. Ctrl+C closes it and stops
# the task; if this terminal dies, the task stops by itself after TUNNEL_HOURS
# (8). Staging's database is off at night and on weekends: the script starts it
# and stops it again when you close the tunnel, unless staging's services came
# up in the meantime.
#
# Needs the Session Manager plugin (brew install --cask session-manager-plugin)
# and an SSO session (aws sso login --sso-session ringee). Uses AWS_PROFILE, or
# ringee-<env> when it is not set. LOCAL_PORT picks another local port.
set -euo pipefail

usage() {
  echo "usage: db-tunnel.sh <prod|staging> [password]" >&2
  exit 2
}

ENV_NAME=${1:-}
case "$ENV_NAME" in
  prod) ACCOUNT=405762675020 DEFAULT_PORT=15432 ;;
  staging) ACCOUNT=699340623836 DEFAULT_PORT=15433 ;;
  *) usage ;;
esac
shift
export AWS_PROFILE=${AWS_PROFILE:-ringee-$ENV_NAME}

CALLER=$(aws sts get-caller-identity --query Account --output text) || {
  echo "no AWS session for $AWS_PROFILE: aws sso login --sso-session ringee" >&2
  exit 1
}
if [[ $CALLER != "$ACCOUNT" ]]; then
  echo "AWS_PROFILE=$AWS_PROFILE is account $CALLER, not $ENV_NAME ($ACCOUNT)" >&2
  exit 1
fi

# ── password: copy it, never print it ────────────────────────────────────────
# The secret is named in modules/secrets.

if [[ ${1:-} == password && $# -eq 1 ]]; then
  aws secretsmanager get-secret-value --secret-id "ringee/$ENV_NAME/editor" --query SecretString --output text |
    python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["password"])' | pbcopy
  echo "password of ringee_editor ($ENV_NAME) copied to the clipboard"
  exit 0
fi
[[ $# -eq 0 ]] || usage

# ── tunnel ───────────────────────────────────────────────────────────────────

LOCAL_PORT=${LOCAL_PORT:-$DEFAULT_PORT}
TUNNEL_HOURS=${TUNNEL_HOURS:-8}

if ! command -v session-manager-plugin >/dev/null; then
  echo "missing the Session Manager plugin: brew install --cask session-manager-plugin" >&2
  exit 1
fi
if lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "localhost:$LOCAL_PORT is already taken (another tunnel?); close it or set LOCAL_PORT" >&2
  exit 1
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUTPUTS=$(terraform -chdir="$ROOT/envs/$ENV_NAME" output -json stack)
out() { python3 -c 'import json,sys; print(eval(sys.argv[1], {"o": json.load(sys.stdin)}))' "$1" <<<"$OUTPUTS"; }

CLUSTER=$(out 'o["cluster_name"]')
SUBNETS=$(out '",".join(o["task_subnet_ids"])')
SECURITY_GROUP=$(out 'o["ops_security_group_id"]')
FAMILY=$(out 'o["task_families"]["ops"]')
DB_ID=$(out 'o["rds_identifier"]')
DB_HOST=$(out 'o["rds_address"]')

TASK_ARN=""
STARTED_DB=false

cleanup() {
  trap - EXIT INT TERM HUP
  if [[ -n $TASK_ARN ]]; then
    aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_ARN" --reason "db-tunnel.sh: closed" >/dev/null 2>&1 || true
    echo "tunnel closed, task stopped"
  fi
  if [[ $STARTED_DB == true ]]; then
    # From 08:00 on a weekday staging's services are up and use the database.
    TASKS=$(aws ecs describe-services --cluster "$CLUSTER" --services api orchestrator temporal \
      --query 'sum(services[].desiredCount)' --output text 2>/dev/null || echo unknown)
    if [[ $TASKS == 0 ]]; then
      if aws rds stop-db-instance --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
        echo "$DB_ID is stopping again"
      else
        echo "could not stop $DB_ID; stop it with: aws rds stop-db-instance --db-instance-identifier $DB_ID" >&2
      fi
    else
      echo "$DB_ID stays on: staging's services are running"
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].DBInstanceStatus' --output text)
case "$DB_STATUS" in
  stopped)
    if [[ $ENV_NAME != staging ]]; then
      echo "$DB_ID is stopped. Production never stops on purpose: not starting it from here." >&2
      exit 1
    fi
    echo "$DB_ID is off (staging runs on weekdays, 08:00-22:00): starting it, 5 to 10 minutes"
    aws rds start-db-instance --db-instance-identifier "$DB_ID" >/dev/null
    STARTED_DB=true
    aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
    ;;
  starting | rebooting)
    echo "$DB_ID is $DB_STATUS: waiting until it is available"
    aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
    ;;
  stopping)
    echo "$DB_ID is stopping; run this again once it has stopped (a few minutes)" >&2
    exit 1
    ;;
esac

OVERRIDES=$(python3 -c 'import json,sys; print(json.dumps({
  "cpu": "256", "memory": "512",
  "containerOverrides": [{"name": "ops", "command": ["sleep", str(int(float(sys.argv[1]) * 3600))]}],
}))' "$TUNNEL_HOURS")

ARN=$(aws ecs run-task \
  --cluster "$CLUSTER" \
  --task-definition "$FAMILY" \
  --launch-type FARGATE \
  --enable-execute-command \
  --started-by "db-tunnel.sh" \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUP],assignPublicIp=ENABLED}" \
  --overrides "$OVERRIDES" \
  --query 'tasks[0].taskArn' --output text)
if [[ $ARN != arn:* ]]; then
  echo "ECS did not start the tunnel task" >&2
  exit 1
fi
TASK_ARN=$ARN
TASK_ID=${TASK_ARN##*/}
echo "starting the tunnel task $TASK_ID (about a minute)"
aws ecs wait tasks-running --cluster "$CLUSTER" --tasks "$TASK_ARN"

AGENT=PENDING
RUNTIME_ID=""
for _ in $(seq 1 60); do
  read -r AGENT RUNTIME_ID <<<"$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
    --query "tasks[0].containers[0].[managedAgents[?name=='ExecuteCommandAgent'].lastStatus | [0], runtimeId]" \
    --output text)"
  [[ $AGENT == RUNNING ]] && break
  sleep 2
done
if [[ $AGENT != RUNNING ]]; then
  echo "the task's Session Manager agent did not start ($AGENT)" >&2
  exit 1
fi

TARGET="ecs:${CLUSTER}_${TASK_ID}_${RUNTIME_ID}"
PARAMETERS=$(python3 -c 'import json,sys; print(json.dumps({"host": [sys.argv[1]], "portNumber": ["5432"], "localPortNumber": [sys.argv[2]]}))' \
  "$DB_HOST" "$LOCAL_PORT")

cat <<EOF

$ENV_NAME: localhost:$LOCAL_PORT -> PostgreSQL, database ringee, SSL mode require
  user ringee_editor, password: scripts/db-tunnel.sh $ENV_NAME password
Ctrl+C closes the tunnel. The task stops by itself after $TUNNEL_HOURS h.

EOF

# Session Manager closes a session after 20 idle minutes, and a network change
# drops it: reopen it on the same task until Ctrl+C.
CLOSING=false
trap 'CLOSING=true' INT
while [[ $CLOSING == false ]]; do
  aws ssm start-session --target "$TARGET" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters "$PARAMETERS" || true
  [[ $CLOSING == true ]] && break
  STATUS=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
    --query 'tasks[0].lastStatus' --output text 2>/dev/null || echo UNKNOWN)
  if [[ $STATUS != RUNNING ]]; then
    echo "the tunnel task is $STATUS" >&2
    exit 1
  fi
  echo "session closed; reopening it (Ctrl+C closes the tunnel)"
  sleep 1
done
