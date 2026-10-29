# Sourced by run-all.sh and cleanup.sh. From the three values the reader sets
# (AWS_REGION, IDC_REGION, TF_STATE_BUCKET), derive everything Terraform needs and
# stop with a message when a lookup fails or is ambiguous.
for tool in terraform aws session-manager-plugin kubectl helm python3 nc; do
  command -v "$tool" >/dev/null || { echo "[ERROR] $tool is not installed"; exit 2; }
done
TFV=$(terraform version | sed -n '1s/^Terraform v//p')
HV=$(helm version --template '{{.Version}}' 2>/dev/null | sed 's/^v//')
version_at_least() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n | head -1)" = "$2" ]; }
version_at_least "$TFV" 1.9 || { echo "[ERROR] Terraform $TFV is older than 1.9"; exit 2; }
version_at_least "$HV" 3.8 || { echo "[ERROR] Helm $HV is older than 3.8"; exit 2; }
aws sts get-caller-identity --query Arn --output text >/dev/null || { echo "[ERROR] the AWS CLI has no valid credentials"; exit 2; }

for v in AWS_REGION IDC_REGION TF_STATE_BUCKET; do
  if [ -z "${!v:-}" ]; then echo "[ERROR] set $v"; exit 2; fi
done
export TF_VAR_region=$AWS_REGION TF_VAR_idc_region=$IDC_REGION
export TF_VAR_cluster_name=${TF_VAR_cluster_name:-ekscap-hub}

if ! TF_STATE_REGION=$(aws s3api get-bucket-location --bucket "$TF_STATE_BUCKET" --query LocationConstraint --output text); then
  echo "[ERROR] cannot read the location of bucket $TF_STATE_BUCKET"; exit 2
fi
# get-bucket-location reports us-east-1 as None and the legacy eu-west-1 as EU.
case $TF_STATE_REGION in None) TF_STATE_REGION=us-east-1 ;; EU) TF_STATE_REGION=eu-west-1 ;; esac
export TF_STATE_REGION

if [ -z "${TF_VAR_idc_admin_user_name:-}" ]; then
  if ! STORE=$(aws sso-admin list-instances --no-paginate --region "$IDC_REGION" --query 'Instances[0].IdentityStoreId' --output text) || [ "$STORE" = None ]; then
    echo "[ERROR] no IAM Identity Center instance in $IDC_REGION"; exit 2
  fi
  if ! USERS=$(aws identitystore list-users --region "$IDC_REGION" --identity-store-id "$STORE" --query 'Users[].UserName' --output text); then
    echo "[ERROR] cannot list Identity Center users"; exit 2
  fi
  set -f; set -- $USERS; set +f
  if [ $# -ne 1 ]; then
    echo "[ERROR] found $# Identity Center users. Paste the line for the user who becomes the Argo CD admin, then run ./scripts/run-all.sh again:"
    for u in "$@"; do echo "export TF_VAR_idc_admin_user_name='$u'"; done
    exit 2
  fi
  export TF_VAR_idc_admin_user_name=$1
fi
echo "[INFO] cluster=$TF_VAR_cluster_name region=$AWS_REGION state=s3://$TF_STATE_BUCKET ($TF_STATE_REGION) argocd admin=$TF_VAR_idc_admin_user_name"
