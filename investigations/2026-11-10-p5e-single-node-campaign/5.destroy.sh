#!/bin/bash
# Delete the FSx file system, terminate the instance, and destroy the stack. The results bucket is kept.
set -euo pipefail
cd "$(dirname "$0")"
. ./env.sh
CFG=$(aws ssm get-parameter --region "$AWS_REGION" --name "/$STACK_NAME/config" --query Parameter.Value --output text 2>/dev/null || true)
if [ -n "$CFG" ]; then
  FN=$(echo "$CFG" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fsxFunction"])')
  aws lambda invoke --region "$AWS_REGION" --function-name "$FN" --cli-binary-format raw-in-base64-out --payload '{"action":"delete"}' /dev/stdout; echo
fi
IIDS=$(aws ec2 describe-instances --region "$AWS_REGION" --filters "Name=tag:Campaign,Values=$STACK_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text)
[ -z "$IIDS" ] || { aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids $IIDS > /dev/null; aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids $IIDS; }
while aws fsx describe-file-systems --region "$AWS_REGION" --query "FileSystems[?Tags[?Key=='Campaign' && Value=='$STACK_NAME']].FileSystemId" --output text | grep -q fs-; do echo "waiting for FSx deletion"; sleep 30; done
cd cdk && CDK_DEFAULT_REGION=$AWS_REGION npx cdk destroy --force -c stackName="$STACK_NAME" -c availabilityZone="$AVAILABILITY_ZONE" -c amiId="$AMI_ID"
