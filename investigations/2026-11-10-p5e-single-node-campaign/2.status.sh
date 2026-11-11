#!/bin/bash
# Show the instance, the FSx file system and the state of every task file on the host.
set -euo pipefail
cd "$(dirname "$0")"
. ./env.sh
IID=${INSTANCE_ID:-}
[ -n "$IID" ] || IID=$(aws ec2 describe-instances --region "$AWS_REGION" --filters "Name=tag:Campaign,Values=$STACK_NAME" "Name=instance-state-name,Values=pending,running" --query 'Reservations[].Instances[].InstanceId' --output text)
echo "instance: ${IID:-none}"
FN=$(aws ssm get-parameter --region "$AWS_REGION" --name "/$STACK_NAME/config" --query Parameter.Value --output text | python3 -c 'import json,sys; print(json.load(sys.stdin)["fsxFunction"])')
aws lambda invoke --region "$AWS_REGION" --function-name "$FN" --cli-binary-format raw-in-base64-out --payload '{"action":"describe"}' /dev/stdout | head -1; echo
[ -n "$IID" ] || exit 0
CMD='tail -n 15 /opt/campaign/results/bootstrap.log; for f in /opt/campaign/results/state/*/*.json; do echo "== $f"; python3 -c "import json,sys;[print(\" \",k,v[\"status\"],v.get(\"sec\")) for k,v in json.load(open(sys.argv[1])).items()]" "$f"; done'
CID=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$IID" --document-name AWS-RunShellScript --parameters "$(python3 -c 'import json,sys; print(json.dumps({"commands":[sys.argv[1]]}))' "$CMD")" --query Command.CommandId --output text)
sleep 4; aws ssm wait command-executed --region "$AWS_REGION" --command-id "$CID" --instance-id "$IID" 2>/dev/null || true
aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$CID" --instance-id "$IID" --query StandardOutputContent --output text
