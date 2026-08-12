#!/usr/bin/env bash
# One-command driver for the opt-in S3 remote state backend.
#
# It runs the declarative bootstrap module (which provisions the versioned,
# encrypted state bucket and the DynamoDB lock table), writes the generated
# backend.hcl next to the root module, installs backend.tf from the example,
# and then prints the single init command that migrates local state to S3.
#
# The bucket/table are created by Terraform (not raw AWS CLI) so they stay
# declarative, idempotent, and drift-managed. This wrapper only sequences the
# steps and wires the bootstrap outputs into the root module's backend config.
#
# Usage (from infra/eks/):
#   scripts/bootstrap-remote-state.sh \
#     -b my-tf-state-bucket -r ap-southeast-4 [-t my-tf-locks] [-k alias/my-key] [-p my-profile]
#
# Re-runnable: bootstrap apply is idempotent, and it will not overwrite an
# existing backend.hcl unless -f is given.
set -euo pipefail

module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bootstrap_dir="${module_dir}/bootstrap"

bucket="" ; region="" ; table="" ; kms="" ; profile="" ; force=false
usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ; exit "${1:-0}" ; }
while getopts "b:r:t:k:p:fh" opt; do
  case "$opt" in
    b) bucket="$OPTARG" ;;
    r) region="$OPTARG" ;;
    t) table="$OPTARG" ;;
    k) kms="$OPTARG" ;;
    p) profile="$OPTARG" ;;
    f) force=true ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done

if [ -z "$bucket" ] || [ -z "$region" ]; then
  echo "error: -b <bucket> and -r <region> are required" >&2
  usage 1
fi
: "${table:=${bucket}-locks}"

backend_hcl="${module_dir}/backend.hcl"
if [ -e "$backend_hcl" ] && [ "$force" = false ]; then
  echo "error: ${backend_hcl} already exists; pass -f to overwrite" >&2
  exit 1
fi

echo "==> Provisioning the state bucket and lock table (bootstrap module)"
tf_args=(-chdir="$bootstrap_dir")
var_args=(-var "region=${region}" -var "state_bucket_name=${bucket}" -var "lock_table_name=${table}")
[ -n "$kms" ] && var_args+=(-var "kms_key_id=${kms}")
[ -n "$profile" ] && var_args+=(-var "aws_profile=${profile}")

terraform "${tf_args[@]}" init -input=false
terraform "${tf_args[@]}" apply -input=false -auto-approve "${var_args[@]}"

echo "==> Writing ${backend_hcl}"
terraform "${tf_args[@]}" output -raw backend_hcl > "$backend_hcl"

if [ ! -e "${module_dir}/backend.tf" ]; then
  echo "==> Installing backend.tf from backend.tf.example"
  cp "${module_dir}/backend.tf.example" "${module_dir}/backend.tf"
fi

cat <<EOF

Remote state is ready. Migrate this module's local state to S3 with:

  terraform -chdir="${module_dir}" init -migrate-state -backend-config=backend.hcl

Terraform will show the source/destination and ask for confirmation before
copying. See docs/remote-state.md for verification and version recovery.
EOF
