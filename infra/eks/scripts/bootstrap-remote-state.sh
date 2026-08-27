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
# The state key is derived from the cluster name (-c) rather than asked for, so
# that the bucket layout, the backend and what the registry later advertises
# cannot disagree. Recording the location is distai-up.sh's job, not this one's:
# this module is shared by every cluster in the account, and per-cluster facts
# must not live in a state that another cluster's run will rewrite.
#
# Usage (from infra/eks/):
#   scripts/bootstrap-remote-state.sh -c my-cluster \
#     -b my-tf-state-bucket -r us-east-2 [-t my-tf-locks] [-k alias/my-key] [-p my-profile]
#
# Every value above is an example. -r is the region the state bucket lives in, which is normally the
# cluster's own region; distai-up.sh derives all of them and calls this, so a hand-run is the
# exception (adopting a bucket that already exists, or repairing a checkout).
#
# Re-runnable: bootstrap apply is idempotent, and it will not overwrite an
# existing backend.hcl unless -f is given.
set -euo pipefail

module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bootstrap_dir="${module_dir}/bootstrap"

cluster="" ; bucket="" ; region="" ; table="" ; kms="" ; profile="" ; force=false
# The help text is the header comment itself, up to the first line that is not a comment.
usage() { sed -n '2,${/^[^#]/q;p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ; exit "${1:-0}" ; }
while getopts "c:b:r:t:k:p:fh" opt; do
  case "$opt" in
    c) cluster="$OPTARG" ;;
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

if [ -z "$cluster" ] || [ -z "$bucket" ] || [ -z "$region" ]; then
  echo "error: -c <cluster>, -b <bucket> and -r <region> are required" >&2
  usage 1
fi
: "${table:=${bucket}-locks}"
state_key="eks/${cluster}/terraform.tfstate"

backend_hcl="${module_dir}/backend.hcl"

echo "==> Provisioning the state bucket and lock table (bootstrap module)"
tf_args=(-chdir="$bootstrap_dir")
var_args=(-var "region=${region}" -var "state_bucket_name=${bucket}" -var "lock_table_name=${table}"
  -var "state_key=${state_key}")
[ -n "$kms" ] && var_args+=(-var "kms_key_id=${kms}")
[ -n "$profile" ] && var_args+=(-var "aws_profile=${profile}")

terraform "${tf_args[@]}" init -input=false

# One bucket and one lock table serve every cluster in the account, but this module's state is local
# to a checkout. A second cluster, or the same cluster from a new machine, therefore finds them
# already present and would fail to create them. They are adopted instead, which is also what makes
# this command safe to run against a foundation someone else bootstrapped.
adopt() {
  local address="$1" id="$2"
  terraform "${tf_args[@]}" state list 2>/dev/null | grep -qx "$address" && return 0
  echo "==> Adopting the existing ${address} (${id})"
  terraform "${tf_args[@]}" import -input=false "${var_args[@]}" "$address" "$id" >/dev/null
}
if aws s3api head-bucket --bucket "$bucket" ${profile:+--profile "$profile"} >/dev/null 2>&1; then
  adopt aws_s3_bucket.state "$bucket"
fi
if aws dynamodb describe-table --table-name "$table" --region "$region" \
  ${profile:+--profile "$profile"} >/dev/null 2>&1; then
  adopt aws_dynamodb_table.lock "$table"
fi

terraform "${tf_args[@]}" apply -input=false -auto-approve "${var_args[@]}"

# Guarding the write, not the whole run: the apply above is idempotent, so re-running this with an
# existing backend.hcl is how an already-bootstrapped cluster gets its registry entries backfilled.
if [ -e "$backend_hcl" ] && [ "$force" = false ]; then
  echo "==> ${backend_hcl} exists; leaving it alone (pass -f to regenerate)"
else
  echo "==> Writing ${backend_hcl}"
  terraform "${tf_args[@]}" output -raw backend_hcl > "$backend_hcl"
fi

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
