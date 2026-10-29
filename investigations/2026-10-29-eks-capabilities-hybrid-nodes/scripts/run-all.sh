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
# The admin lookup returns every user name; refuse to guess which one is meant.
case $TF_VAR_idc_admin_user_name in
  *[[:space:]]*) echo "[ERROR] several Identity Center users found; set TF_VAR_idc_admin_user_name to one of: $TF_VAR_idc_admin_user_name"; exit 2 ;;
esac

terraform -chdir="$TFDIR" init -input=false \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="key=eks/${TF_VAR_cluster_name:-ekscap-hub}/terraform.tfstate" \
  -backend-config="region=$TF_STATE_REGION" || exit 3
# The final destroy removes everything in this state, so it must start empty.
STATE_LIST=$(terraform -chdir="$TFDIR" state list) || { echo "[ERROR] could not read the state"; exit 3; }
if [ -n "$STATE_LIST" ]; then
  echo "[ERROR] state key eks/${TF_VAR_cluster_name:-ekscap-hub}/terraform.tfstate is not empty; set TF_VAR_cluster_name to a new name or run cleanup.sh for it"
  exit 4
fi

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
