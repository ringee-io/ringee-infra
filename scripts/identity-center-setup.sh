#!/usr/bin/env bash
# One-time IAM Identity Center setup for the Ringee organization (AWS-03):
# your user, the ringee-admins group, the AdministratorAccess and
# ReadOnlyAccess permission sets (8 h sessions) on the three accounts, and the
# SSO profiles in ~/.aws/config. Safe to run again: it creates only what is
# missing and never deletes.
#
# From the management account, after enabling Identity Center in us-east-1:
#   scripts/identity-center-setup.sh edison@getringee.com Edison Padilla
set -euo pipefail

EMAIL=${1:?usage: identity-center-setup.sh <email> <given name> <family name>}
GIVEN=${2:?usage: identity-center-setup.sh <email> <given name> <family name>}
FAMILY=${3:?usage: identity-center-setup.sh <email> <given name> <family name>}
GROUP=ringee-admins
SESSION=PT8H
export AWS_REGION=us-east-1
log() { echo "$*" >&2; }

read -r INSTANCE_ARN STORE_ID <<<"$(aws sso-admin list-instances --query 'Instances[0].[InstanceArn,IdentityStoreId]' --output text)"
[[ $INSTANCE_ARN == arn:* ]] || { log "IAM Identity Center is not enabled in $AWS_REGION yet."; exit 1; }

MANAGEMENT=$(aws organizations describe-organization --query 'Organization.MasterAccountId' --output text)
account_id() { aws organizations list-accounts --query "Accounts[?Name=='$1'].Id | [0]" --output text; }
PROD=$(account_id ringee-prod)
STAGING=$(account_id ringee-staging)
[[ $PROD =~ ^[0-9]{12}$ && $STAGING =~ ^[0-9]{12}$ ]] || { log "ringee-prod or ringee-staging not found in the organization."; exit 1; }

unique() { printf '{"UniqueAttribute":{"AttributePath":"%s","AttributeValue":"%s"}}' "$1" "$2"; }

# ── User and group ───────────────────────────────────────────────────────────
USER_ID=$(aws identitystore get-user-id --identity-store-id "$STORE_ID" \
  --alternate-identifier "$(unique userName "$EMAIL")" --query UserId --output text 2>/dev/null || true)
if [[ -z $USER_ID || $USER_ID == None ]]; then
  USER_ID=$(aws identitystore create-user --identity-store-id "$STORE_ID" --user-name "$EMAIL" \
    --display-name "$GIVEN $FAMILY" --name "GivenName=$GIVEN,FamilyName=$FAMILY" \
    --emails "Value=$EMAIL,Type=work,Primary=true" --query UserId --output text)
  log "user created: $EMAIL"
else
  log "user exists: $EMAIL"
fi

GROUP_ID=$(aws identitystore get-group-id --identity-store-id "$STORE_ID" \
  --alternate-identifier "$(unique displayName "$GROUP")" --query GroupId --output text 2>/dev/null || true)
if [[ -z $GROUP_ID || $GROUP_ID == None ]]; then
  GROUP_ID=$(aws identitystore create-group --identity-store-id "$STORE_ID" --display-name "$GROUP" \
    --description "Ringee administrators" --query GroupId --output text)
  log "group created: $GROUP"
else
  log "group exists: $GROUP"
fi

if ! aws identitystore get-group-membership-id --identity-store-id "$STORE_ID" --group-id "$GROUP_ID" \
  --member-id "UserId=$USER_ID" >/dev/null 2>&1; then
  aws identitystore create-group-membership --identity-store-id "$STORE_ID" --group-id "$GROUP_ID" \
    --member-id "UserId=$USER_ID" >/dev/null
  log "$EMAIL added to $GROUP"
fi

# ── Permission sets ──────────────────────────────────────────────────────────
permission_set() { # <name> <managed policy ARN> <description>
  local arn=""
  for candidate in $(aws sso-admin list-permission-sets --instance-arn "$INSTANCE_ARN" --query 'PermissionSets[]' --output text); do
    if [[ $(aws sso-admin describe-permission-set --instance-arn "$INSTANCE_ARN" --permission-set-arn "$candidate" \
      --query 'PermissionSet.Name' --output text) == "$1" ]]; then
      arn=$candidate
    fi
  done
  if [[ -z $arn ]]; then
    arn=$(aws sso-admin create-permission-set --instance-arn "$INSTANCE_ARN" --name "$1" --description "$3" \
      --session-duration "$SESSION" --query 'PermissionSet.PermissionSetArn' --output text)
    aws sso-admin attach-managed-policy-to-permission-set --instance-arn "$INSTANCE_ARN" \
      --permission-set-arn "$arn" --managed-policy-arn "$2"
    log "permission set created: $1"
  else
    log "permission set exists: $1"
  fi
  echo "$arn"
}
ADMIN=$(permission_set AdministratorAccess arn:aws:iam::aws:policy/AdministratorAccess "Full access")
READONLY=$(permission_set ReadOnlyAccess arn:aws:iam::aws:policy/ReadOnlyAccess "Read-only access")

# ── Assignments: the group gets both sets on every account ───────────────────
assign() { # <account id> <permission set ARN> <label>
  local present request status
  present=$(aws sso-admin list-account-assignments --instance-arn "$INSTANCE_ARN" --account-id "$1" \
    --permission-set-arn "$2" --query "length(AccountAssignments[?PrincipalId=='$GROUP_ID'])" --output text)
  if [[ $present != 0 ]]; then
    log "assigned already: $3"
    return
  fi
  request=$(aws sso-admin create-account-assignment --instance-arn "$INSTANCE_ARN" --target-id "$1" \
    --target-type AWS_ACCOUNT --permission-set-arn "$2" --principal-type GROUP --principal-id "$GROUP_ID" \
    --query 'AccountAssignmentCreationStatus.RequestId' --output text)
  for _ in $(seq 1 30); do
    status=$(aws sso-admin describe-account-assignment-creation-status --instance-arn "$INSTANCE_ARN" \
      --account-assignment-creation-request-id "$request" --query 'AccountAssignmentCreationStatus.Status' --output text)
    [[ $status != IN_PROGRESS ]] && break
    sleep 3
  done
  [[ $status == SUCCEEDED ]] || { log "assignment failed: $3 ($status)"; exit 1; }
  log "assigned: $3"
}
for pair in "management:$MANAGEMENT" "prod:$PROD" "staging:$STAGING"; do
  assign "${pair#*:}" "$ADMIN" "${pair%%:*} AdministratorAccess"
  assign "${pair#*:}" "$READONLY" "${pair%%:*} ReadOnlyAccess"
done

# ── CLI profiles (appended once; existing sections are left alone) ───────────
CONFIG=${AWS_CONFIG_FILE:-$HOME/.aws/config}
mkdir -p "$(dirname "$CONFIG")"
touch "$CONFIG"
add_section() { # <header> <body>
  if ! grep -qxF "[$1]" "$CONFIG"; then
    printf '\n[%s]\n%s\n' "$1" "$2" >>"$CONFIG"
    log "~/.aws/config: added [$1]"
  fi
}
add_section "sso-session ringee" "sso_start_url = https://$STORE_ID.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access"
profile() { # <name> <account> <role>
  add_section "profile $1" "sso_session = ringee
sso_account_id = $2
sso_role_name = $3
region = us-east-1"
}
profile ringee-management "$MANAGEMENT" AdministratorAccess
profile ringee-prod "$PROD" AdministratorAccess
profile ringee-staging "$STAGING" AdministratorAccess
profile ringee-prod-readonly "$PROD" ReadOnlyAccess

log ""
log "Access portal: https://$STORE_ID.awsapps.com/start"
log "Next: aws sso login --sso-session ringee"
