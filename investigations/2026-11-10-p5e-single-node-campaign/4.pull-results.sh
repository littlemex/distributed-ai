#!/bin/bash
# Download a run's results from S3 (default: the latest run) and copy each investigation's part into
# its own results/ directory.
set -euo pipefail
cd "$(dirname "$0")"
. ./env.sh
BUCKET=$(aws ssm get-parameter --region "$AWS_REGION" --name "/$STACK_NAME/config" --query Parameter.Value --output text | python3 -c 'import json,sys; print(json.load(sys.stdin)["bucket"])')
RUN=${1:-$(aws s3 cp --region "$AWS_REGION" "s3://$BUCKET/runs/LATEST" -)}
DEST=${DEST:-$HOME/tmp/p5e-campaign/runs/$RUN}
mkdir -p "$DEST" && aws s3 sync --region "$AWS_REGION" "s3://$BUCKET/runs/$RUN/" "$DEST/" --only-show-errors
for d in "$DEST"/*/; do n=$(basename "$d"); [ -d "../$n" ] && mkdir -p "../$n/results/$RUN" && rsync -a --exclude '*.bin' "$d" "../$n/results/$RUN/"; done
echo "$DEST"
