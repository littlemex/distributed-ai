#!/bin/bash
# Remove everything terraform/ created. Hybrid nodes stay registered in Systems
# Manager as managed instances after the machines are gone, so deregister them too.
# terraform destroy always runs, even when a deregistration fails; the exit status
# is non-zero if either step failed.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/env.sh"
TFDIR="$HERE/../terraform"
DEREG=0
# After a partial build the output may not exist yet; destroy must still run.
# Without the output, fall back to the role name prefix (the filter matches prefixes).
ROLE=$(terraform -chdir="$TFDIR" output -raw hybrid_node_role_name 2>/dev/null || true)
ROLE_EXACT=1
[ -n "$ROLE" ] || { ROLE=$TF_VAR_cluster_name-hybrid-node; ROLE_EXACT=0; }
if [ -n "$ROLE" ]; then
  # The filter matches by prefix; keep only exact matches when the output gave the name.
  if [ "$ROLE_EXACT" = 1 ]; then Q="InstanceInformationList[?IamRole=='$ROLE'].InstanceId"; else Q='InstanceInformationList[].InstanceId'; fi
  IDS=$(aws ssm describe-instance-information --region "$AWS_REGION" \
    --filters "Key=IamRole,Values=$ROLE" --query "$Q" --output text) || DEREG=1
  for ID in $IDS; do
    echo "[INFO] deregistering $ID"
    aws ssm deregister-managed-instance --region "$AWS_REGION" --instance-id "$ID" || DEREG=1
  done
fi
terraform -chdir="$TFDIR" destroy -auto-approve -input=false; DESTROY=$?
if STATE_LIST=$(terraform -chdir="$TFDIR" state list); then
  LEFT=$(printf '%s' "$STATE_LIST" | grep -c . || true)
else
  LEFT=unknown
fi
echo "[INFO] deregister=$DEREG destroy=$DESTROY resources left in state=$LEFT"
[ "$DEREG" = 0 ] && [ "$DESTROY" = 0 ] && [ "$LEFT" = 0 ]
