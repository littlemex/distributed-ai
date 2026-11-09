#!/bin/bash
# Run one task file on the instance through SSM Run Command (no SSH). The bundle is refreshed first.
# INSTANCE_ID overrides the instance lookup (for example a dry-run instance).
#   ./3.run.sh <investigation>/tasks/<file>.json [--only ID] [--force]
set -euo pipefail
cd "$(dirname "$0")"
. ./env.sh
TF=$1; shift
IID=${INSTANCE_ID:-}
[ -n "$IID" ] || IID=$(aws ec2 describe-instances --region "$AWS_REGION" --filters "Name=tag:Campaign,Values=$STACK_NAME" "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text)
CMD="set -a; . /opt/campaign/env; set +a; aws s3 sync s3://\$BUCKET/bundle/ \$BUNDLE/ --only-show-errors && find \$BUNDLE -name '*.sh' -exec chmod +x {} + ; cd \$BUNDLE && ./2026-11-10-p5e-single-node-campaign/host/task_runner.sh $TF $*"
CID=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$IID" --document-name AWS-RunShellScript --parameters "$(python3 -c 'import json,sys; print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":["86400"]}))' "$CMD")" --query Command.CommandId --output text)
echo "command $CID on $IID"
while true; do
  S=$(aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$CID" --instance-id "$IID" --query Status --output text 2>/dev/null || echo Pending)
  case $S in Pending|InProgress|Delayed) sleep 10 ;; *) break ;; esac
done
aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$CID" --instance-id "$IID" --query '[StandardOutputContent,StandardErrorContent]' --output text | tail -n 60
[ "$S" = Success ]
