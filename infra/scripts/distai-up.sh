#!/usr/bin/env bash
# distai-up.sh — from an empty account to an applied cluster, in one re-runnable command.
#
#   export CLUSTER_NAME=my-cluster AWS_REGION=us-east-2
#   infra/scripts/distai-up.sh
#
# It sequences the four things that have to happen before any workshop chapter can run, and records
# where it put them so that every later chapter needs only the cluster's name:
#
#   1. the S3 state bucket and its lock table            (infra/eks/bootstrap, idempotent)
#   2. backend.hcl and backend.tf next to infra/eks      (untracked, environment-specific)
#   3. terraform.tfvars                                  (generated from the example, then yours)
#   4. terraform init / plan / apply                     (the plan is shown, the apply is confirmed)
#
# Afterwards it stamps the release the cluster was applied with, which is what lets a chapter written
# for one release notice that it is looking at a cluster built from another.
#
# Inputs, all from the environment, so that the names are the same ones every later chapter uses
# with distai-env.sh and a reader has one set to remember:
#   CLUSTER_NAME  cluster to create or apply to. Becomes the registry path and the state key.
#   AWS_REGION    region. Falls back to the AWS CLI's configured region.
#   AWS_PROFILE   optional named profile. Passed to terraform and written into the tfvars.
#
# Options:
#   -y          skip the confirmation gate. For CI. Do not put this in documentation.
#
# Environment:
#   DISTAI_SHARED_STORAGE=off   generate a tfvars with FSx Lustre and OpenZFS disabled. They are on by
#                               default because the workshop's training samples mount them, and they
#                               are the largest standing cost of an idle cluster.
#
# Re-running is safe. Every step checks before it acts, and a failure is resumed by running the same
# command again; there is no step file, because a step file is one more thing that can disagree with
# reality. Nothing here is destroyed and nothing is rolled back.
set -euo pipefail

# The help text is the header comment itself, up to the first line that is not a comment.
usage() { sed -n '2,${/^[^#]/q;p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
say() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

infra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eks_dir="${infra_dir}/eks"

cluster="${CLUSTER_NAME:-}" region="${AWS_REGION:-}" profile="${AWS_PROFILE:-}" assume_yes=false
while getopts "yh" opt; do
  case "${opt}" in
    y) assume_yes=true ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done
[ -n "${cluster}" ] ||
  { printf 'error: CLUSTER_NAME is not set. export CLUSTER_NAME=<cluster> and run this again.\n' >&2; usage 1; }
printf '%s' "${cluster}" | grep -Eq '^[a-z0-9][a-z0-9-]{1,62}$' ||
  die "cluster name must match ^[a-z0-9][a-z0-9-]{1,62}$ (it becomes an SSM path and a state key)"
[ -z "${profile}" ] || export AWS_PROFILE="${profile}"

# ── phase 1: preflight ──────────────────────────────────────────────────────────────────────────
say "Phase 1/5: preflight"
missing=""
for cmd in aws terraform kubectl helm python3 git; do
  command -v "${cmd}" >/dev/null 2>&1 || missing="${missing} ${cmd}"
done
[ -z "${missing}" ] || die "missing required commands:${missing}"

account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" ||
  die "no usable AWS credentials. Sign in first, or pass -p <profile>."
caller_arn="$(aws sts get-caller-identity --query Arn --output text)"

# The registry answers "does this name already belong to someone?" before anything is created.
prefix="/distai/v1/clusters/${cluster}"
[ -n "${region}" ] || region="$(aws configure get region 2>/dev/null || true)"
[ -n "${region}" ] ||
  die "AWS_REGION is not set and the AWS CLI has no configured region. A cluster name alone does not name a cluster."
export AWS_REGION="${region}"

registered_account="$(aws ssm get-parameter --name "${prefix}/meta/account-id" --region "${region}" \
  --query Parameter.Value --output text 2>/dev/null || true)"
if [ -n "${registered_account}" ] && [ "${registered_account}" != "${account}" ]; then
  die "cluster '${cluster}' is registered in account ${registered_account}, but these credentials are ${account}"
fi
existing="$(aws eks describe-cluster --name "${cluster}" --region "${region}" \
  --query cluster.status --output text 2>/dev/null || true)"

release="$(git -C "${infra_dir}" describe --tags --always --dirty 2>/dev/null || echo unknown)"

printf '    account   : %s\n' "${account}"
printf '    caller    : %s\n' "${caller_arn}"
printf '    region    : %s\n' "${region}"
printf '    cluster   : %s (%s)\n' "${cluster}" "${existing:-not created yet}"
printf '    release   : %s\n' "${release}"
printf '    registry  : %s\n' "${prefix}"

# ── phase 2: consent ────────────────────────────────────────────────────────────────────────────
# The gate is here, before the first billable resource, and it asks for the cluster's name rather
# than a y/n: the mistake this catches is running against the wrong cluster or account, and a "y" is
# too easy to type without reading what is above it.
if [ "${assume_yes}" != true ]; then
  say "Phase 2/5: confirm"
  if [ -n "${existing}" ]; then
    printf '    This will APPLY to the EXISTING cluster %s.\n' "${cluster}"
  else
    printf '    This will CREATE an EKS cluster, its VPC, system nodes and Karpenter.\n'
    printf '    Standing cost is dominated by the control plane, the system nodes and, unless\n'
    printf '    DISTAI_SHARED_STORAGE=off, the FSx Lustre and OpenZFS filesystems.\n'
  fi
  printf '\n    Type the cluster name to continue: '
  read -r typed </dev/tty || die "no terminal to confirm on. Re-run with -y if this is automation."
  [ "${typed}" = "${cluster}" ] || die "got '${typed}', expected '${cluster}'. Nothing was changed."
else
  say "Phase 2/5: confirm skipped (-y)"
fi

# ── phase 3: state and the registry ─────────────────────────────────────────────────────────────
say "Phase 3/5: remote state and registry"
state_bucket="$(aws ssm get-parameter --name "${prefix}/state/bucket" --region "${region}" \
  --query Parameter.Value --output text 2>/dev/null || true)"
# One bucket per account and region, one key per cluster. Derived, so that two clusters never argue
# over a name and nobody has to invent one.
: "${state_bucket:=distai-tfstate-${account}-${region}}"

bootstrap_args=(-c "${cluster}" -b "${state_bucket}" -r "${region}")
[ -n "${profile}" ] && bootstrap_args+=(-p "${profile}")
if [ -f "${eks_dir}/backend.hcl" ]; then
  # Same reasoning as terraform.tfvars below: an existing backend that points at another cluster's
  # state is a checkout that belongs to that cluster, and overwriting it would strand it.
  backend_val() { awk -F\" -v k="$1" '$0 ~ "^[[:space:]]*"k"[[:space:]]*=" {print $2; exit}' "${eks_dir}/backend.hcl"; }
  [ "$(backend_val key)" = "eks/${cluster}/terraform.tfstate" ] ||
    die "${eks_dir}/backend.hcl points at key '$(backend_val key)', not this cluster's state. Use a separate checkout per cluster."
  [ "$(backend_val region)" = "${region}" ] ||
    die "${eks_dir}/backend.hcl is in region '$(backend_val region)', but this run targets '${region}'."
  say "backend.hcl exists and matches; the bootstrap run will backfill the registry and leave it alone"
fi
"${eks_dir}/scripts/bootstrap-remote-state.sh" "${bootstrap_args[@]}"

# The registry is written here rather than by the bootstrap module, even though that module creates the
# bucket, because the bucket is shared by every cluster in the account while these facts are per
# cluster: managing them there would make each cluster's run rewrite the previous cluster's entries.
# The guard that this gives up — a create that fails when the name is taken — is kept explicitly in
# phase 1, which refuses to continue when the name already belongs to another account.
say "recording where the state lives"
put() {
  aws ssm put-parameter --name "${prefix}/$1" --type String --overwrite \
    --value "$2" --region "${region}" >/dev/null
}
hcl_val() { awk -F\" -v k="$1" '$0 ~ "^[[:space:]]*"k"[[:space:]]*=" {print $2; exit}' "${eks_dir}/backend.hcl"; }
put state/bucket "${state_bucket}"
put state/key "eks/${cluster}/terraform.tfstate"
put state/lock-table "$(hcl_val dynamodb_table)"
put state/kms-key-id "$(hcl_val kms_key_id)"
put meta/account-id "${account}"
printf '    %s/state/{bucket,key,lock-table,kms-key-id}\n' "${prefix}"

# ── phase 4: variables ──────────────────────────────────────────────────────────────────────────
say "Phase 4/5: variables"
tfvars="${eks_dir}/terraform.tfvars"
if [ -f "${tfvars}" ]; then
  # A checkout carries the variables of the cluster it manages. If those name a different cluster,
  # this run would apply that cluster's configuration under this cluster's state, so it stops here
  # rather than generating a plan that looks plausible and is not.
  in_tfvars="$(awk -F'"' '/^[[:space:]]*cluster_name[[:space:]]*=/{print $2}' "${tfvars}" | head -1)"
  [ -z "${in_tfvars}" ] || [ "${in_tfvars}" = "${cluster}" ] ||
    die "${tfvars} is for cluster '${in_tfvars}', not '${cluster}'. Use a separate checkout per cluster, or edit it deliberately."
  in_region="$(awk -F'"' '/^[[:space:]]*region[[:space:]]*=/{print $2}' "${tfvars}" | head -1)"
  [ -z "${in_region}" ] || [ "${in_region}" = "${region}" ] ||
    die "${tfvars} says region '${in_region}', but this run targets '${region}'. A cluster name means nothing without its region."
  say "${tfvars} exists; leaving it alone"
else
  say "generating ${tfvars}"
  tmp_tfvars="$(mktemp)"
  {
    printf '# Generated by infra/scripts/distai-up.sh. Edit freely: it is yours from now on.\n'
    printf 'region              = "%s"\n' "${region}"
    printf 'cluster_name        = "%s"\n' "${cluster}"
    [ -n "${profile}" ] && printf 'aws_profile         = "%s"\n' "${profile}"
    # Pinned because the account is already known here, and this is the guard that stops a later
    # `terraform apply` with a mistaken profile from re-creating the cluster somewhere else.
    printf 'expected_account_id = "%s"\n' "${account}"
    if [ "${DISTAI_SHARED_STORAGE:-on}" = "off" ]; then
      printf '\n# DISTAI_SHARED_STORAGE=off: no FSx Lustre, no OpenZFS. The training samples that mount\n'
      printf '# /shared will not run until these are turned back on.\n'
      printf 'fsx_enabled     = false\n'
      printf 'openzfs_enabled = false\n'
    fi
  } >"${tmp_tfvars}"
  # Written aside and moved into place: a failure half way through would otherwise leave a partial
  # tfvars that the next run treats as "already exists" and skips.
  mv "${tmp_tfvars}" "${tfvars}"
fi
printf '    accelerator pools are NOT generated: GPU and Capacity Block nodes stay an explicit opt-in\n'
printf '    (copy infra/eks/accelerator-pools.tfvars.example when a later chapter asks for them)\n'

# ── phase 5: apply ──────────────────────────────────────────────────────────────────────────────
say "Phase 5/5: terraform"
terraform -chdir="${eks_dir}" init -input=false -reconfigure -backend-config=backend.hcl >/dev/null
plan_file="$(mktemp)"
trap 'rm -f "${plan_file}"' EXIT
terraform -chdir="${eks_dir}" plan -input=false -out="${plan_file}" >/dev/null
# awk does the limiting rather than head: under `set -o pipefail`, a head that closes the pipe early
# makes the whole display pipeline fail, which would abort the run between plan and apply.
terraform -chdir="${eks_dir}" show -no-color "${plan_file}" | awk '
  /^(Plan:|No changes)/ { print }
  /^  # / { n++; if (n <= 40) { sub(/^  # /, "    "); print } }
  END { if (n > 40) printf "    ... and %d more\n", n - 40 }'

if [ "${assume_yes}" != true ]; then
  printf '\n    Apply this plan? Type the cluster name: '
  read -r typed </dev/tty || die "no terminal to confirm on"
  [ "${typed}" = "${cluster}" ] || die "not applying. The plan above was discarded."
fi
terraform -chdir="${eks_dir}" apply -input=false "${plan_file}"

# The release is stamped after the apply succeeded, because that is when it becomes true. It is
# written by this script rather than by Terraform: a git tag is not a property of the infrastructure,
# and threading it through a -var would make it flap for anyone who runs terraform directly.
say "recording the release"
aws ssm put-parameter --name "${prefix}/meta/release" --type String --overwrite \
  --value "${release}" --region "${region}" >/dev/null
aws ssm get-parameter --name "${prefix}/meta/created-release" --region "${region}" >/dev/null 2>&1 ||
  aws ssm put-parameter --name "${prefix}/meta/created-release" --type String \
    --value "${release}" --region "${region}" >/dev/null

aws eks update-kubeconfig --name "${cluster}" --region "${region}" >/dev/null

cat <<EOF

Cluster ${cluster} is applied and registered.

Every chapter from here starts with these four lines:

  cd ${infra_dir%/infra}
  export CLUSTER_NAME=${cluster}
  export AWS_REGION=${region}
  source infra/scripts/distai-env.sh

That resolves the account, the state's location and the attached data layers from the registry, so no
chapter needs a bucket name or a state key again. The region is given rather than resolved because a
cluster is identified by account, region and name: left unset, the AWS CLI's own default region
decides where to look, and a default that differs from this cluster's is a lookup that fails.
EOF
