#!/bin/bash
# Upload the investigation directories the plan uses to s3://<bucket>/bundle/. The instance pulls the
# bundle at boot, and 3.run.sh pulls it again before every run, so later edits reach a running host.
set -euo pipefail
cd "$(dirname "$0")"
. ./env.sh
BUCKET=$(aws ssm get-parameter --region "$AWS_REGION" --name "/$STACK_NAME/config" --query Parameter.Value --output text | python3 -c 'import json,sys; print(json.load(sys.stdin)["bucket"])')
ROOT=$(cd .. && pwd)
DIRS=$(sed -e 's/#.*//' -e '/^\s*$/d' host/plan.txt | cut -d/ -f1 | sort -u)
for d in $(basename "$(pwd)") $DIRS; do
  COPYFILE_DISABLE=1 aws s3 sync --region "$AWS_REGION" "$ROOT/$d" "s3://$BUCKET/bundle/$d/" --delete --only-show-errors \
    --exclude 'cdk/node_modules/*' --exclude 'cdk/cdk.out/*' --exclude '*.pyc' --exclude '__pycache__/*' --exclude 'results/*' --exclude 'env.sh'
  echo "uploaded $d"
done
