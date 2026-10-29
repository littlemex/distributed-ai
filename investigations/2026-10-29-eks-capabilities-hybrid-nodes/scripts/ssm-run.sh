#!/bin/bash
# Run a shell command on a machine through SSM Run Command and print its stdout.
# usage: ssm-run.sh <instance-or-managed-instance-id> <command>
set -euo pipefail
: "${AWS_REGION:?}"
ID=$1; shift
CID=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$ID" --document-name AWS-RunShellScript \
  --parameters "$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]]}))' "$*")" \
  --query Command.CommandId --output text)
S=Pending
for _ in $(seq 100); do
  S=$(aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$CID" --instance-id "$ID" --query Status --output text 2>/dev/null || echo Pending)
  case $S in Pending|InProgress|Delayed) sleep 3 ;; *) break ;; esac
done
aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$CID" --instance-id "$ID" --query StandardOutputContent --output text
[ "$S" = Success ]
