#!/bin/bash
# Remove everything terraform/ created. Hybrid nodes stay registered in Systems
# Manager as managed instances after the machines are gone, so deregister them first.
set -euo pipefail
: "${AWS_REGION:?}"
HERE=$(cd "$(dirname "$0")" && pwd)
# After a partial build the output may not exist yet; destroy must still run.
ROLE=$(terraform -chdir="$HERE/../terraform" output -raw hybrid_node_role_name 2>/dev/null || true)
if [ -n "$ROLE" ]; then
  for ID in $(aws ssm describe-instance-information --region "$AWS_REGION" \
      --filters "Key=IamRole,Values=$ROLE" --query 'InstanceInformationList[].InstanceId' --output text); do
    echo "[INFO] deregistering $ID"
    aws ssm deregister-managed-instance --region "$AWS_REGION" --instance-id "$ID"
  done
fi
terraform -chdir="$HERE/../terraform" destroy -auto-approve -input=false
