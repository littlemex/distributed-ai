# distai-env.sh — resolve a cluster's execution context from its name. MEANT TO BE SOURCED.
#
#   export CLUSTER_NAME=my-cluster
#   source "$(git rev-parse --show-toplevel)/infra/scripts/distai-env.sh"
#
# Every workshop chapter starts with those two lines and needs nothing else. What it resolves:
#
#   AWS_REGION                 from the environment, else the AWS CLI's configured region
#   DISTAI_ACCOUNT_ID          the account the cluster belongs to, per the registry
#   DISTAI_STATE_BUCKET/KEY/LOCK_TABLE/KMS_KEY_ID   where the cluster's Terraform state lives
#   DISTAI_RELEASE             release tag the cluster was last applied with
#   DISTAI_CREATED_RELEASE     release tag it was created with
#   DISTAI_DATA_LAYER          the cluster's default data layer, if one is attached
#   DISTAI_DATA_LAYERS         every data layer attached to it
#
# Only the first four come from the registry because only they cannot come from Terraform: the state
# cannot record its own address, and a fresh checkout has no backend.hcl to read it from. Everything
# else about the cluster stays behind `terraform output`, which this makes possible by writing
# backend.hcl when it is absent.
#
# It is sourced rather than run because its job is to leave variables behind in the caller's shell.
# That has consequences it must respect: no `set -e`, no `exit`, and nothing on stdout, so that a
# chapter's own command substitution is never polluted. Failures return non-zero and say what to fix.
#
# Read-only. It creates nothing in AWS and applies nothing. The one file it may write is backend.hcl,
# and only when missing.

_distai_say() { printf 'distai-env: %s\n' "$*" >&2; }
_distai_warn() { printf 'distai-env: warning: %s\n' "$*" >&2; }
_distai_fail() { printf 'distai-env: error: %s\n' "$*" >&2; }

_distai_resolve() {
  local cluster region prefix params eks_dir
  cluster="${CLUSTER_NAME:-}"
  if [ -z "${cluster}" ]; then
    _distai_fail "CLUSTER_NAME is not set. Set it to the cluster this chapter works with, e.g. export CLUSTER_NAME=distai-eks"
    return 1
  fi

  # A cluster is identified by (account, region, name); the name alone is ambiguous, so the region is
  # resolved rather than assumed, and never defaulted to a guess.
  region="${AWS_REGION:-}"
  [ -n "${region}" ] || region="$(aws configure get region 2>/dev/null || true)"
  if [ -z "${region}" ]; then
    _distai_fail "no region. Set AWS_REGION, or configure one with 'aws configure set region <region>'"
    return 1
  fi

  prefix="/distai/v1/clusters/${cluster}"
  # The CLI pages through get-parameters-by-path for us; a hand-rolled API caller would have to
  # follow NextToken, and a reader that only takes the first page silently loses data layers.
  if ! params="$(aws ssm get-parameters-by-path --path "${prefix}" --recursive \
    --region "${region}" --output json 2>/dev/null)"; then
    _distai_fail "cannot read the registry at ${prefix} in ${region}. Check credentials and ssm:GetParametersByPath."
    return 1
  fi

  local resolved
  resolved="$(printf '%s' "${params}" | PREFIX="${prefix}" python3 -c '
import json, os, sys, shlex
prefix = os.environ["PREFIX"]
by_name = {p["Name"][len(prefix):].lstrip("/"): p["Value"] for p in json.load(sys.stdin)["Parameters"]}
layers = sorted({k.split("/")[1] for k in by_name if k.startswith("data-layers/")})
out = {
    "DISTAI_STATE_BUCKET": by_name.get("state/bucket", ""),
    "DISTAI_STATE_KEY": by_name.get("state/key", ""),
    "DISTAI_STATE_LOCK_TABLE": by_name.get("state/lock-table", ""),
    "DISTAI_STATE_KMS_KEY_ID": by_name.get("state/kms-key-id", "alias/aws/s3"),
    "DISTAI_ACCOUNT_ID": by_name.get("meta/account-id", ""),
    "DISTAI_RELEASE": by_name.get("meta/release", ""),
    "DISTAI_CREATED_RELEASE": by_name.get("meta/created-release", ""),
    "DISTAI_DATA_LAYER": by_name.get("defaults/data-layer", ""),
    "DISTAI_DATA_LAYERS": " ".join(layers),
}
for k, v in out.items():
    print(f"{k}={shlex.quote(v)}")
')" || { _distai_fail "could not parse the registry response"; return 1; }
  eval "${resolved}"

  if [ -z "${DISTAI_STATE_BUCKET}" ] && [ -z "${DISTAI_STATE_KEY}" ] && [ -z "${DISTAI_ACCOUNT_ID}" ]; then
    _distai_fail "cluster '${cluster}' is not in the registry in ${region}. Create it with infra/scripts/distai-up.sh, or check the name and region."
    return 1
  fi
  # A partial registration is worse than none: it would produce a backend.hcl with empty fields, and
  # terraform would then init against a bucket called "".
  local missing=""
  [ -n "${DISTAI_STATE_BUCKET}" ] || missing="${missing} state/bucket"
  [ -n "${DISTAI_STATE_KEY}" ] || missing="${missing} state/key"
  [ -n "${DISTAI_STATE_LOCK_TABLE}" ] || missing="${missing} state/lock-table"
  [ -n "${DISTAI_ACCOUNT_ID}" ] || missing="${missing} meta/account-id"
  if [ -n "${missing}" ]; then
    _distai_fail "the registry entry for '${cluster}' is incomplete, missing:${missing}. Re-run infra/scripts/distai-up.sh to repair it."
    return 1
  fi

  # The wrong-account guard. The registry says which account owns this name; if the caller is
  # somewhere else, they have resolved someone else's cluster and must not go on to plan against it.
  # Fail closed: a guard that skips itself when the identity cannot be read is not a guard. Both sides
  # of the comparison must be present for the check to have been performed.
  local caller
  if ! caller="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || [ -z "${caller}" ]; then
    _distai_fail "cannot read the calling identity, so the account of '${cluster}' cannot be verified. Check credentials."
    return 1
  fi
  if [ "${caller}" != "${DISTAI_ACCOUNT_ID}" ]; then
    _distai_fail "cluster '${cluster}' belongs to account ${DISTAI_ACCOUNT_ID}, but these credentials are ${caller}"
    return 1
  fi

  export AWS_REGION="${region}"
  export DISTAI_CLUSTER="${cluster}"
  export DISTAI_ACCOUNT_ID DISTAI_STATE_BUCKET DISTAI_STATE_KEY DISTAI_STATE_LOCK_TABLE DISTAI_STATE_KMS_KEY_ID
  export DISTAI_RELEASE DISTAI_CREATED_RELEASE DISTAI_DATA_LAYER DISTAI_DATA_LAYERS

  # backend.hcl is untracked, so a fresh checkout has none and cannot init. Writing it from the
  # registry is the whole point of recording the state's address. An existing one is left alone: it
  # is what terraform actually uses, so it wins, and a disagreement is reported rather than resolved.
  # Located through git rather than from this file's own path: a sourced script cannot portably know
  # where it lives (bash exposes BASH_SOURCE, zsh does not, and zsh is the default shell on macOS),
  # and this file only ever runs from inside the checkout it belongs to.
  eks_dir=""
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "${root}" ] && [ -d "${root}/infra/eks" ] && eks_dir="${root}/infra/eks"
  if [ -z "${eks_dir}" ]; then
    _distai_warn "not inside the checkout, so backend.hcl was not written. Run this from the repository."
  fi
  if [ -n "${eks_dir}" ]; then
    if [ ! -f "${eks_dir}/backend.hcl" ]; then
      _distai_say "writing ${eks_dir}/backend.hcl from the registry"
      cat >"${eks_dir}/backend.hcl" <<HCL
# Generated by infra/scripts/distai-env.sh from /distai/v1/clusters/${cluster}/state/*.
bucket         = "${DISTAI_STATE_BUCKET}"
key            = "${DISTAI_STATE_KEY}"
region         = "${AWS_REGION}"
dynamodb_table = "${DISTAI_STATE_LOCK_TABLE}"

encrypt    = true
kms_key_id = "${DISTAI_STATE_KMS_KEY_ID}"
HCL
      [ -f "${eks_dir}/backend.tf" ] || cp "${eks_dir}/backend.tf.example" "${eks_dir}/backend.tf"
    else
      # Compared field by field: a key alone repeats across accounts and regions, so matching only the
      # key would call two different states the same one.
      local field expected actual
      for field in bucket:"${DISTAI_STATE_BUCKET}" key:"${DISTAI_STATE_KEY}" region:"${AWS_REGION}"; do
        expected="${field#*:}"
        actual="$(awk -F'"' -v k="${field%%:*}" '$0 ~ "^[[:space:]]*"k"[[:space:]]*=" {print $2; exit}' "${eks_dir}/backend.hcl")"
        if [ -n "${actual}" ] && [ "${actual}" != "${expected}" ]; then
          _distai_warn "backend.hcl ${field%%:*} is '${actual}' but the registry says '${expected}'. terraform uses backend.hcl."
        fi
      done
    fi
  fi

  # A chapter written against one release can say so; a cluster built from another is then a warning
  # with a name, instead of a plan full of changes nobody asked for.
  if [ -n "${DISTAI_EXPECT_RELEASE:-}" ] && [ -n "${DISTAI_RELEASE}" ] &&
    [ "${DISTAI_EXPECT_RELEASE}" != "${DISTAI_RELEASE}" ]; then
    _distai_warn "this chapter expects ${DISTAI_EXPECT_RELEASE}, but ${cluster} was last applied with ${DISTAI_RELEASE}"
  fi

  _distai_say "${cluster} in ${AWS_REGION} (account ${DISTAI_ACCOUNT_ID}, release ${DISTAI_RELEASE:-unrecorded}, data layer ${DISTAI_DATA_LAYER:-none})"
}

_distai_resolve
_distai_status=$?
unset -f _distai_resolve _distai_say _distai_warn _distai_fail
return ${_distai_status} 2>/dev/null || true
