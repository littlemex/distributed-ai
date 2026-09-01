#!/usr/bin/env bash
# get-profiling.sh — fetch this repository at the release this file belongs to and install the
# kubectl-accelprof plugin from it, then run the platform installer if this machine has what the
# cluster's Terraform needs. One command, re-runnable.
#
# Two audiences, one script:
#
#   Someone who profiles workloads needs the client and nothing else. One line gives them the plugin
#   from a known release, with no checkout and no Terraform.
#
#   The platform owner also runs install-profiling.sh. That reaches into the cluster's Terraform
#   state, which is configured by files this repository deliberately does not track (backend.hcl and
#   terraform.tfvars are environment-specific). A clone made by this script therefore cannot plan the
#   cluster on its own: without those files Terraform would resolve variable defaults and produce a
#   destructive plan. So the installer runs from here only when the state's location is supplied and
#   the cluster's variables are present; otherwise this script stops after installing the plugin and
#   says what is missing. The install itself is then one command from the checkout that owns them.
#
# Usage:
#   export CLUSTER_NAME=my-cluster AWS_REGION=us-east-2 PRODUCER_NAMESPACES=team-a,team-b
#   curl -fsSL https://raw.githubusercontent.com/littlemex/distributed-ai/refs/tags/release/eks-distributed-ai/v0.2.1/infra/scripts/get-profiling.sh | bash
#
# The URL pins the release twice over: the copy of this script is the one from that tag, and PIN
# below is that same tag, so the tree it checks out is the tree this script was released with. To
# install a different release, use that release's URL rather than overriding PIN.
#
# Required:
#   CLUSTER_NAME          EKS cluster to work with
#   AWS_REGION            region of the cluster
#   PRODUCER_NAMESPACES   comma-separated namespaces whose workloads may collect profiles. They must
#                         already exist, with a mcp-producer ServiceAccount in each; the installer
#                         skips namespaces that do not.
#
# To have this script also run the installer, additionally:
#   TF_STATE_BUCKET       where the cluster's Terraform state lives, its region and its object key
#   TF_STATE_REGION       (TF_STATE_LOCK_TABLE too, if the state is locked with DynamoDB), and
#   TF_STATE_KEY          EKS_TFVARS pointing at the cluster's terraform.tfvars, which is copied
#   EKS_TFVARS            into the checkout. Without these, the plugin is installed and this script
#                         stops, because a plan without the cluster's variables is a destructive one.
#
# Optional:
#   PROFILING_DIR         where to keep the checkout (default ~/distributed-ai-<release>)
#   PROFILING_BIN_DIR     where to install the kubectl plugin (default ~/.local/bin)
#   RUN_INSTALL=0         never run the installer, even when everything for it is present
#   CREATE_DATA_LAYER=1   first install in an account: allow creating the shared data layer
#   PIN                   override the git ref to check out. Only for developing this script.
#
# Everything else (DATA_LAYER_NAME, ALLOW_UNRELATED, PROFILING_ONLY, AWS_PROFILE, ...) is passed
# straight through to install-profiling.sh; see infra/docs/profiling-install.md.
set -euo pipefail

# An exported but empty AWS_PROFILE is not "no profile" to the AWS CLI: it looks for a profile named ""
# and fails, and what it prints is usually about credentials or the resource being read rather than
# about the empty string, so the symptom lands far from the cause. Treat it as unset, which is what a
# shell that ran `export AWS_PROFILE=` meant. AWS_DEFAULT_PROFILE is the same variable for the v1 CLI
# and for boto3, so it gets the same treatment rather than becoming the next occurrence of this.
[ -n "${AWS_PROFILE:-}" ] || unset AWS_PROFILE
[ -n "${AWS_DEFAULT_PROFILE:-}" ] || unset AWS_DEFAULT_PROFILE

# The release this file was published with. It is written out in full rather than derived, so that a
# copy of this script pulled from anywhere still installs exactly one known tree.
PIN_DEFAULT="release/eks-distributed-ai/v0.2.1"
pin="${PIN:-${PIN_DEFAULT}}"
repo_url="${PROFILING_REPO_URL:-https://github.com/littlemex/distributed-ai.git}"
bin_dir="${PROFILING_BIN_DIR:-${HOME}/.local/bin}"
dir="${PROFILING_DIR:-${HOME}/distributed-ai-${pin##*/}}"

say() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

say "profiling platform ${pin}"

# ── preflight ───────────────────────────────────────────────────────────────────────────────────
# Checked here rather than inside the installer as well, because the point of this script is that a
# newcomer runs one line: finding out about a missing terraform after a clone is a worse experience.
missing=""
for cmd in git terraform kubectl helm aws python3 curl; do
  command -v "${cmd}" >/dev/null 2>&1 || missing="${missing} ${cmd}"
done
[ -z "${missing}" ] || die "missing required commands:${missing}"

for var in CLUSTER_NAME AWS_REGION PRODUCER_NAMESPACES; do
  [ -n "${!var:-}" ] || die "${var} is required. See the usage block at the top of this script."
done

# ── the pinned tree ─────────────────────────────────────────────────────────────────────────────
# A tag, not a branch: the checkout is detached on purpose, so a later run of a NEWER release's
# one-liner lands in its own directory instead of fast-forwarding this one underneath you.
if [ ! -e "${dir}" ]; then
  say "cloning ${repo_url} at ${pin} into ${dir}"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${pin}" "${repo_url}" "${dir}"
elif [ -d "${dir}/.git" ]; then
  [ -z "$(git -C "${dir}" status --porcelain)" ] ||
    die "${dir} has local changes. Commit, stash or remove them, or point PROFILING_DIR elsewhere."
  if [ "$(git -C "${dir}" rev-parse HEAD)" = "$(git -C "${dir}" rev-parse "refs/tags/${pin}^{commit}" 2>/dev/null || echo none)" ]; then
    say "${dir} is already at ${pin}"
  else
    say "updating ${dir} to ${pin}"
    git -C "${dir}" fetch --quiet --depth 1 origin "refs/tags/${pin}:refs/tags/${pin}"
    git -C "${dir}" -c advice.detachedHead=false checkout --quiet --detach "refs/tags/${pin}"
  fi
else
  die "${dir} exists but is not a git checkout. Remove it or point PROFILING_DIR elsewhere."
fi

installer="${dir}/infra/scripts/install-profiling.sh"
client="${dir}/infra/eks/bin/kubectl-accelprof"
[ -x "${installer}" ] || die "${installer} is missing from ${pin}; is PIN a release of this platform?"

# ── the kubectl plugin ──────────────────────────────────────────────────────────────────────────
# Copied rather than symlinked: it is a single self-contained file precisely so that it survives
# being moved onto PATH, and a copy cannot be broken later by updating the checkout.
say "installing kubectl-accelprof into ${bin_dir}"
mkdir -p "${bin_dir}"
install -m 0755 "${client}" "${bin_dir}/kubectl-accelprof"
case ":${PATH}:" in
  *":${bin_dir}:"*) : ;;
  *) warn "${bin_dir} is not on PATH. Add it to use the plugin: export PATH=\"${bin_dir}:\$PATH\"" ;;
esac

# ── the installer, when this machine has what the cluster's Terraform needs ──────────────────────
# Checked before running rather than after failing, because the failure mode of a plan without the
# cluster's variables is not an error message: it is a plan that proposes to destroy the cluster's
# storage and add-ons, and the operator then has to recognise that.
missing_for_install=""
[ -n "${TF_STATE_BUCKET:-}" ] || missing_for_install="${missing_for_install} TF_STATE_BUCKET"
[ -n "${TF_STATE_REGION:-}" ] || missing_for_install="${missing_for_install} TF_STATE_REGION"
[ -n "${TF_STATE_KEY:-}" ] || missing_for_install="${missing_for_install} TF_STATE_KEY"
[ -n "${EKS_TFVARS:-}" ] || missing_for_install="${missing_for_install} EKS_TFVARS"

if [ "${RUN_INSTALL:-1}" != "1" ] || [ -n "${missing_for_install}" ]; then
  say "the plugin is installed; not running the installer"
  if [ -n "${missing_for_install}" ]; then
    printf '    %s\n' "this clone has no cluster configuration of its own, and these are unset:${missing_for_install}"
    printf '    %s\n' "install the platform from the checkout that manages ${CLUSTER_NAME}:"
    printf '\n      CLUSTER_NAME=%s AWS_REGION=%s PRODUCER_NAMESPACES=%s \\\n        infra/scripts/install-profiling.sh\n\n' \
      "${CLUSTER_NAME}" "${AWS_REGION}" "${PRODUCER_NAMESPACES}"
    printf '    %s\n' "or set the four variables above and re-run this one-liner."
  else
    printf '    run it yourself with: %s\n' "${installer}"
  fi
  exit 0
fi

[ -f "${EKS_TFVARS}" ] || die "EKS_TFVARS=${EKS_TFVARS} does not exist"
say "copying ${EKS_TFVARS} into the checkout"
cp "${EKS_TFVARS}" "${dir}/infra/eks/terraform.tfvars"

# stdin is redirected because this script is usually read from a pipe (curl | bash): whatever is left
# on stdin belongs to bash, not to the installer.
say "running the installer"
exec "${installer}" </dev/null
