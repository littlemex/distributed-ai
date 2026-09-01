# distai-env.sh — resolve a cluster's execution context from its name. MEANT TO BE SOURCED.
#
#   export CLUSTER_NAME=my-cluster
#   export AWS_REGION=us-east-2
#   source "$(git rev-parse --show-toplevel)/infra/scripts/distai-env.sh"
#
# Every workshop chapter starts with those lines and needs nothing else. The region is one of them
# because a cluster is (account, region, name): with AWS_REGION unset the AWS CLI's own default region
# decides where to look, and a default that differs from the cluster's is a lookup that fails. What it
# resolves:
#
#   AWS_REGION                 from the environment, else the AWS CLI's configured region
#   DISTAI_ACCOUNT_ID          the account the cluster belongs to, per the registry
#   DISTAI_STATE_BUCKET/KEY/LOCK_TABLE/KMS_KEY_ID   where the cluster's Terraform state lives
#   DISTAI_RELEASE             release tag the cluster was last applied with
#   DISTAI_CREATED_RELEASE     release tag it was created with
#   DISTAI_DATA_LAYER          the cluster's default data layer, if one is attached
#   DISTAI_DATA_LAYERS         every data layer attached to it
#   DISTAI_CONTEXT             the kubectl context for this cluster
#   DISTAI_NAMESPACE           the namespace chapters work in. Default distai. Set it before sourcing
#                              to override, and it stays overridden for the rest of the shell.
#   KUBECONFIG                 a kubeconfig for this cluster and namespace alone, rewritten each time
#
# It also leaves `k` as a shorthand for kubectl, and points kubectl at this cluster and at the working
# namespace, so that no chapter has to spell out update-kubeconfig, use-context and set-context again.
# Doing that here is the reason it is sourced: a shell function and an exported KUBECONFIG only survive
# if the shell itself runs the file. `k` is a function rather than an alias because an alias is not
# expanded in a non-interactive shell, so a script that sourced this would find `k` missing.
#
# The kubeconfig it writes is a file of its own (~/.kube/distai/<cluster>.<namespace>.yaml), not an
# entry in the default one. Sourcing this for one cluster would otherwise repoint every terminal and
# every tool that reads ~/.kube/config at whatever cluster was resolved last, which is a bad thing to
# do to someone who has another cluster open next door. The only shell this changes is this one; the
# only file it touches is its own.
#
# What the registry holds is what Terraform cannot: the state's own address (a state cannot record
# where it lives, and a fresh checkout has no backend.hcl to read it from), the release a cluster was
# created and last applied with, and which data layers are attached to it. Everything else about the
# cluster stays behind `terraform output`, which this makes possible by writing backend.hcl when it is
# absent. Nothing here is a copy of something Terraform already knows.
#
# It is sourced rather than run because its job is to leave variables behind in the caller's shell.
# That has consequences it must respect: no `set -e`, no `exit`, and nothing on stdout, so that a
# chapter's own command substitution is never polluted. Failures return non-zero and say what to fix.
#
# Nothing in AWS is created or applied; every AWS call it makes is a read. Locally it writes backend.hcl
# when it is missing (and copies backend.tf from its example if that is missing too, since a backend
# block is what makes the file mean anything), and the kubeconfig above. DISTAI_DEFINE_K=0 skips
# defining `k`; DISTAI_KUBECONFIG overrides where the kubeconfig goes; DISTAI_EXPECT_RELEASE warns
# when the cluster was last applied with another release.


# An exported but empty AWS_PROFILE is not "no profile" to the AWS CLI: it looks for a profile named ""
# and fails, and what it prints is usually about credentials or the resource being read rather than
# about the empty string, so the symptom lands far from the cause. Treat it as unset, which is what a
# shell that ran `export AWS_PROFILE=` meant. AWS_DEFAULT_PROFILE is the same variable for the v1 CLI
# and for boto3, so it gets the same treatment rather than becoming the next occurrence of this.
[ -n "${AWS_PROFILE:-}" ] || unset AWS_PROFILE
[ -n "${AWS_DEFAULT_PROFILE:-}" ] || unset AWS_DEFAULT_PROFILE
_distai_say() { printf 'distai-env: %s\n' "$*" >&2; }
_distai_warn() { printf 'distai-env: warning: %s\n' "$*" >&2; }
_distai_fail() { printf 'distai-env: error: %s\n' "$*" >&2; }

_distai_resolve() {
  local cluster region prefix params eks_dir
  # Whatever a previous source of this file left behind is dropped up front, before any path that can
  # return early. A resolution that fails must not leave `k` quietly pointed at the cluster resolved
  # last: a mistyped CLUSTER_NAME would then keep working, against the wrong cluster. Dropping our own
  # KUBECONFIG (and only ours) puts the shell back where it was before this file was ever sourced.
  # Everything this file exports goes, not just the kubectl pointer. A resolve that stops early would
  # otherwise leave the previous cluster's state bucket, release and data layer in the environment,
  # and the next command in the chapter would use them as if they belonged to the cluster just named.
  unset DISTAI_CLUSTER DISTAI_ACCOUNT_ID DISTAI_STATE_BUCKET DISTAI_STATE_KEY \
    DISTAI_STATE_LOCK_TABLE DISTAI_STATE_KMS_KEY_ID DISTAI_RELEASE DISTAI_CREATED_RELEASE \
    DISTAI_DATA_LAYER DISTAI_DATA_LAYERS
  if [ -n "${DISTAI_CONTEXT:-}" ]; then
    unset DISTAI_CONTEXT
    case "${KUBECONFIG:-}" in "${HOME}/.kube/distai/"*) unset KUBECONFIG ;; esac
  fi
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
        actual="$(awk -F'"' -v k="${field%%:*}" '$0 ~ "^[[:space:]]*"k"[[:space:]]*=" {print $2; exit}' \
          "${eks_dir}/backend.hcl" 2>/dev/null || true)"
        if [ -n "${actual}" ] && [ "${actual}" != "${expected}" ]; then
          _distai_warn "backend.hcl ${field%%:*} is '${actual}' but the registry says '${expected}'. terraform uses backend.hcl."
        fi
      done
    fi
  fi

  # ── kubectl, pointed at this cluster and at nothing else ──────────────────────────────────────
  #
  # The kubeconfig is per cluster and per namespace. Per cluster is obvious; per namespace is because
  # the namespace is stored in the file, so two shells on the same cluster with different namespaces
  # — the profiling chapter's team-a next to a window on distai — would otherwise rewrite each other's
  # default behind their backs, and the bare kubectl in one of them would start acting elsewhere.
  local namespace="${DISTAI_NAMESPACE:-distai}"
  local kubeconfig="${DISTAI_KUBECONFIG:-${HOME}/.kube/distai/${cluster}.${namespace}.yaml}"
  if ! command -v kubectl >/dev/null 2>&1; then
    _distai_warn "kubectl is not installed; the k commands in the chapters will not work"
  elif ! mkdir -p "$(dirname "${kubeconfig}")" 2>/dev/null; then
    _distai_warn "cannot create $(dirname "${kubeconfig}"); kubectl is left as it was"
  else
    local kube_err="" kube_rc=0
    # Rewritten on every source rather than only when absent: a cluster rebuilt under the same name
    # gets a new endpoint and a new CA, and a stale entry then fails in a way that reads like a broken
    # cluster. The call is a read against EKS and is idempotent. Written in two branches, with no
    # array, because an empty array under `set -u` is an error in the bash that ships with macOS.
    # `|| kube_rc=$?` on every capture, here and below: this file is sourced, so an assignment whose
    # command fails would abort the caller's shell outright under its own `set -e`, and the caller would
    # see one of bash's internal messages instead of ours.
    if [ -n "${AWS_PROFILE:-}" ]; then
      kube_err="$( { KUBECONFIG="${kubeconfig}" aws eks update-kubeconfig --name "${cluster}" \
        --region "${AWS_REGION}" --alias "${cluster}" --profile "${AWS_PROFILE}" >/dev/null; } 2>&1 )" ||
        kube_rc=$?
    else
      kube_err="$( { KUBECONFIG="${kubeconfig}" aws eks update-kubeconfig --name "${cluster}" \
        --region "${AWS_REGION}" --alias "${cluster}" >/dev/null; } 2>&1 )" || kube_rc=$?
    fi
    if [ "${kube_rc}" -eq 0 ]; then
      export KUBECONFIG="${kubeconfig}"
      # The namespace goes on the context, not into the k wrapper, so that a bare kubectl in this shell
      # — including the ones terraform's kubernetes and helm providers run — agrees with what k does.
      if kubectl config use-context "${cluster}" >/dev/null 2>&1 &&
        kubectl config set-context --current --namespace="${namespace}" >/dev/null 2>&1; then
        export DISTAI_CONTEXT="${cluster}"
        export DISTAI_NAMESPACE="${namespace}"
      else
        _distai_warn "wrote ${kubeconfig} but could not select the context in it"
      fi
    else
      # The reason is kept rather than discarded. "no such cluster", "expired credentials" and "this
      # profile cannot describe it" need different answers, and only the message distinguishes them.
      _distai_warn "aws eks update-kubeconfig failed for ${cluster} in ${AWS_REGION}: $(printf '%s' "${kube_err:-exit ${kube_rc}}" | tail -1)"
      _distai_warn "kubectl is left as it was; nothing in the chapters that uses k will work yet"
    fi
  fi

  # k names the context on every call. With a kubeconfig of its own that is already unambiguous, so
  # this is for the case that is not: a shell where something else has since changed the current
  # context, or a chapter that sets KUBECONFIG for a moment. Which cluster a command lands on should
  # not depend on what ran before it.
  #
  # A function, not an alias, because an alias is not expanded in a non-interactive shell and a script
  # that sourced this would then find k missing. It is defined through eval so that the definition is
  # parsed after the unalias below: a reader who already has `alias k=kubectl` in their rc file would
  # otherwise have this file's `k() { ... }` alias-expanded while the file is being read, which in bash
  # silently defines kubectl() instead, and in zsh is a parse error that abandons the rest of the file.
  if [ "${DISTAI_DEFINE_K:-1}" = "1" ]; then
    unalias k 2>/dev/null || true
    eval 'k() {
      if [ -n "${DISTAI_CONTEXT:-}" ]; then
        command kubectl --context "${DISTAI_CONTEXT}" "$@"
      else
        command kubectl "$@"
      fi
    }'
  fi

  # A chapter written against one release can say so; a cluster built from another is then a warning
  # with a name, instead of a plan full of changes nobody asked for.
  if [ -n "${DISTAI_EXPECT_RELEASE:-}" ] && [ -n "${DISTAI_RELEASE}" ] &&
    [ "${DISTAI_EXPECT_RELEASE}" != "${DISTAI_RELEASE}" ]; then
    _distai_warn "this chapter expects ${DISTAI_EXPECT_RELEASE}, but ${cluster} was last applied with ${DISTAI_RELEASE}"
  fi

  _distai_say "${cluster} in ${AWS_REGION} (account ${DISTAI_ACCOUNT_ID}, release ${DISTAI_RELEASE:-unrecorded}, data layer ${DISTAI_DATA_LAYER:-none})"
  # Which cluster and which namespace kubectl will now act on, in the same breath. "Am I pointed at the
  # right thing" is the question worth answering before it is asked. One read of the namespace itself
  # answers three of them at once: whether the endpoint is reachable at all, whether the credentials
  # are accepted, and whether the namespace the chapters use exists yet.
  if [ -n "${DISTAI_CONTEXT:-}" ]; then
    local server probe note=""
    server="$(kubectl config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null || true)"
    probe="$( { kubectl --request-timeout=10s get --raw "/api/v1/namespaces/${DISTAI_NAMESPACE}" \
      >/dev/null; } 2>&1 )" || true
    case "${probe}" in
      "") ;;
      *NotFound* | *"not found"*) note=" (the namespace does not exist yet)" ;;
      *) note=" (unreachable: $(printf '%s' "${probe}" | tail -1))" ;;
    esac
    _distai_say "kubectl: context ${DISTAI_CONTEXT}, namespace ${DISTAI_NAMESPACE} at ${server:-an unknown endpoint}${note}"
    if [ "${DISTAI_DEFINE_K:-1}" = "1" ]; then
      _distai_say "k is kubectl --context ${DISTAI_CONTEXT}; KUBECONFIG is ${KUBECONFIG}"
    else
      _distai_say "KUBECONFIG is ${KUBECONFIG}; k was left as it was (DISTAI_DEFINE_K=0)"
    fi
  else
    _distai_warn "kubectl is not pointed at ${cluster}; nothing in the chapters that uses k will work yet"
  fi
}

# `|| _distai_status=$?` rather than a bare call: this file is sourced, and a bare command that fails
# would trip the caller's own `set -e` before the status could be captured and returned — killing the
# shell of a reader whose only mistake was a mistyped cluster name.
_distai_status=0
_distai_resolve || _distai_status=$?
unset -f _distai_resolve _distai_say _distai_warn _distai_fail
return ${_distai_status} 2>/dev/null || true
