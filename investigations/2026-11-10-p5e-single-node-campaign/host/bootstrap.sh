#!/bin/bash
# EC2 user data. Reads the campaign config from SSM, pulls the code bundle from S3, starts a results
# sync loop, then runs every task file listed in plan.txt with task_runner.sh, in order.
# A failed task file does not stop the plan; its log and state are synced like any other.
CONFIG_PARAM=__CONFIG_PARAM__
export AWS_DEFAULT_REGION=__REGION__
export CAMPAIGN_ROOT=/opt/campaign
export RESULTS_DIR=$CAMPAIGN_ROOT/results BUNDLE=$CAMPAIGN_ROOT/bundle
mkdir -p "$RESULTS_DIR" "$BUNDLE"
exec > >(tee -a "$RESULTS_DIR/bootstrap.log") 2>&1

command -v aws >/dev/null || { apt-get update -y && apt-get install -y awscli; }
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')
md() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
IID=$(md instance-id); ITYPE=$(md instance-type)
CFG=$(aws ssm get-parameter --name "$CONFIG_PARAM" --query Parameter.Value --output text)
j() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$CFG" "$1"; }
BUCKET=$(j bucket); FSX_FUNCTION=$(j fsxFunction)
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$ITYPE-$IID
# Every task sees these through the environment file.
cat > "$CAMPAIGN_ROOT/env" <<ENV
AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION
CAMPAIGN_ROOT=$CAMPAIGN_ROOT
RESULTS_DIR=$RESULTS_DIR
BUNDLE=$BUNDLE
BUCKET=$BUCKET
FSX_FUNCTION=$FSX_FUNCTION
RUN_ID=$RUN_ID
IID=$IID
ITYPE=$ITYPE
ENV
echo "[INFO] run $RUN_ID bucket $BUCKET"

cat > /etc/systemd/system/campaign-sync.service <<UNIT
[Unit]
Description=sync campaign results to S3 every minute
[Service]
Environment=AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION
ExecStart=/bin/bash -c 'while true; do aws s3 sync $RESULTS_DIR s3://$BUCKET/runs/$RUN_ID/ --only-show-errors; sleep 60; done'
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable --now campaign-sync.service
echo "$RUN_ID" | aws s3 cp - "s3://$BUCKET/runs/LATEST"

aws s3 sync "s3://$BUCKET/bundle/" "$BUNDLE/" --only-show-errors
H=$BUNDLE/2026-11-10-p5e-single-node-campaign/host
find "$BUNDLE" -name "*.sh" -exec chmod +x {} +
set -a; . "$CAMPAIGN_ROOT/env"; set +a
# The full plan on the Capacity Block instance; a short smoke plan on anything else (dry runs on a
# small GPU instance before the block opens).
case $ITYPE in p5*|p6*) PLAN=plan.txt ;; *) PLAN=plan-smoke.txt ;; esac
echo "[INFO] plan $PLAN"
cd "$BUNDLE"
while read -r tf; do
  [ -z "$tf" ] || [[ $tf == \#* ]] && continue
  "$H/task_runner.sh" "$tf" || echo "[WARN] $tf failed, continuing with the next task file"
  aws s3 sync "$RESULTS_DIR" "s3://$BUCKET/runs/$RUN_ID/" --only-show-errors
done < "$H/$PLAN"
echo "[INFO] plan finished $(date -Is)"
touch "$RESULTS_DIR/PLAN_DONE"
aws s3 sync "$RESULTS_DIR" "s3://$BUCKET/runs/$RUN_ID/" --only-show-errors
