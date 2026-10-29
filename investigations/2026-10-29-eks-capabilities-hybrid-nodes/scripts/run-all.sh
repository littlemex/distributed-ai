#!/bin/bash
# Build the environment, run verify.sh, and delete everything, in that order. The
# deletion runs even when the build or the checks fail, so nothing is left billing.
# Exits 0 only when the build, every check and the deletion all succeeded.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TFDIR="$HERE/../terraform"

for v in AWS_REGION TF_STATE_BUCKET TF_STATE_REGION TF_VAR_region TF_VAR_idc_region TF_VAR_idc_admin_user_name; do
  val=${!v:-}
  if [ -z "$val" ] || [ "$val" = None ]; then echo "[ERROR] $v is empty or None"; exit 2; fi
done

terraform -chdir="$TFDIR" init -input=false \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="key=eks/${TF_VAR_cluster_name:-ekscap-hub}/terraform.tfstate" \
  -backend-config="region=$TF_STATE_REGION" || exit 3

BUILD=0; VERIFY=1
terraform -chdir="$TFDIR" apply -auto-approve -input=false || BUILD=$?
if [ "$BUILD" = 0 ]; then
  "$HERE/verify.sh"; VERIFY=$?
else
  echo "[ERROR] terraform apply failed ($BUILD); skipping the checks"
fi
"$HERE/cleanup.sh"; CLEANUP=$?

echo "build=$BUILD verify=$VERIFY cleanup=$CLEANUP"
[ "$BUILD" = 0 ] && [ "$VERIFY" = 0 ] && [ "$CLEANUP" = 0 ]
