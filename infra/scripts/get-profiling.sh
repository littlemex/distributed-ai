#!/usr/bin/env bash
# get-profiling.sh — fetch this repository at the release this file belongs to, then install the
# profiling platform onto an existing infra/eks cluster. One command, re-runnable.
#
# It exists because install-profiling.sh needs the repository around it (two Terraform states, the
# Helm chart, the image definitions), so "one command" cannot be a single file: it has to be a
# command that GETS the pinned tree and then runs the installer inside it. That is all this does.
#
# Usage:
#   export CLUSTER_NAME=my-cluster AWS_REGION=us-east-2 PRODUCER_NAMESPACES=team-a,team-b
#   curl -fsSL https://raw.githubusercontent.com/littlemex/distributed-ai/refs/tags/release/eks-distributed-ai/v0.0.2/infra/scripts/get-profiling.sh | bash
#
# The URL pins the release twice over: the copy of this script is the one from that tag, and PIN
# below is that same tag, so the tree it checks out is the tree this script was released with. To
# install a different release, use that release's URL rather than overriding PIN.
#
# Required:
#   CLUSTER_NAME          EKS cluster to wire (must already exist)
#   AWS_REGION            region of the cluster
#   PRODUCER_NAMESPACES   comma-separated namespaces whose workloads may collect profiles. They must
#                         already exist, with a mcp-producer ServiceAccount in each; the installer
#                         skips namespaces that do not.
#
# Optional:
#   PROFILING_DIR         where to keep the checkout (default ~/distributed-ai-<release>)
#   PROFILING_BIN_DIR     where to install the kubectl plugin (default ~/.local/bin)
#   RUN_INSTALL=0         fetch the tree and install the plugin, but do not run the installer
#   CREATE_DATA_LAYER=1   first install in an account: allow creating the shared data layer
#   PIN                   override the git ref to check out. Only for developing this script.
#
# Everything else (DATA_LAYER_NAME, ALLOW_UNRELATED, TF_STATE_*, AWS_PROFILE, ...) is passed straight
# through to install-profiling.sh; see infra/docs/profiling-install.md.
set -euo pipefail

# The release this file was published with. It is written out in full rather than derived, so that a
# copy of this script pulled from anywhere still installs exactly one known tree.
PIN_DEFAULT="release/eks-distributed-ai/v0.0.2"
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

if [ "${RUN_INSTALL:-1}" != "1" ]; then
  say "RUN_INSTALL=0, stopping before the installer"
  printf '    run it yourself with: %s\n' "${installer}"
  exit 0
fi

# stdin is redirected because this script is usually read from a pipe (curl | bash): whatever is left
# on stdin belongs to bash, not to the installer.
say "running the installer"
exec "${installer}" </dev/null
