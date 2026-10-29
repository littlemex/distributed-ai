#!/bin/bash
# Remove everything terraform/ created. Hybrid nodes stay registered in Systems
# Manager as managed instances after the machines are gone, so deregister them first.
set -euo pipefail
: "${AWS_REGION:?}"
HERE=$(cd "$(dirname "$0")" && pwd)
ROLE=$(terraform -chdir="$HERE/../terraform" output -raw hybrid_node_role_name)
for ID in $(aws ssm describe-instance-information --region "$AWS_REGION" \
    --filters "Key=IamRole,Values=$ROLE" --query 'InstanceInformationList[].InstanceId' --output text); do
  echo "[INFO] deregistering $ID"
  aws ssm deregister-managed-instance --region "$AWS_REGION" --instance-id "$ID"
done
terraform -chdir="$HERE/../terraform" destroy -auto-approve -input=false
