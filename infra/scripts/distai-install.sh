#!/usr/bin/env bash
# distai-install.sh — the one command that gets you from nothing to ready to build a cluster.
#
#   curl -fsSL https://raw.githubusercontent.com/littlemex/distributed-ai/refs/tags/RELEASE/infra/scripts/distai-install.sh | bash
#
# It checks the prerequisites, clones this repository at the release this file came from, and prints
# the next command. It creates nothing in AWS.
#
# That boundary is the point. A pipe from curl into a shell is the wrong place to create an EKS
# cluster: the caller cannot read the plan first, cannot see where a failure stopped, and cannot
# answer a prompt, because the pipe is already using stdin. So this half fetches, and the interactive
# half — distai-up.sh, inside the clone — is what applies.
#
# Environment:
#   DISTAI_DIR   where to clone (default ~/distributed-ai-<release>)
#   PIN          git ref to clone. Only for developing this script; use the release's own URL instead.
set -euo pipefail

# The release this file was published with, written out rather than derived so that a copy of this
# script fetched from anywhere still installs one known tree. It has to be the tag this file is
# published under: a default of "main" would make the URL pin a release and the clone pin something
# else, and a reader who followed the book would get a tree the book was never written against.
PIN_DEFAULT="release/eks-distributed-ai/v0.1.0"
pin="${PIN:-${PIN_DEFAULT}}"
repo_url="${DISTAI_REPO_URL:-https://github.com/littlemex/distributed-ai.git}"
dir="${DISTAI_DIR:-${HOME}/distributed-ai-${pin##*/}}"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

say "distributed-ai ${pin}"

missing=""
for cmd in git curl aws terraform kubectl helm python3; do
  command -v "${cmd}" >/dev/null 2>&1 || missing="${missing} ${cmd}"
done
[ -z "${missing}" ] || die "missing required commands:${missing}"
aws sts get-caller-identity >/dev/null 2>&1 ||
  die "no usable AWS credentials. Sign in, or set AWS_PROFILE, before running this."

if [ ! -e "${dir}" ]; then
  say "cloning ${repo_url} at ${pin} into ${dir}"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${pin}" "${repo_url}" "${dir}"
elif [ -d "${dir}/.git" ]; then
  [ -z "$(git -C "${dir}" status --porcelain)" ] ||
    die "${dir} has local changes. Commit, stash or remove them, or point DISTAI_DIR elsewhere."
  say "${dir} exists; fetching ${pin}"
  git -C "${dir}" fetch --quiet --depth 1 origin "${pin}"
  git -C "${dir}" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
else
  die "${dir} exists but is not a git checkout. Remove it or point DISTAI_DIR elsewhere."
fi

# The next steps are printed with the values this run already has, so that a caller who exported them
# before piping this script sees their own cluster and region rather than an example they then have to
# remember to change. Only what is still unset falls back to a placeholder.
cluster_hint="${CLUSTER_NAME:-my-cluster}"
region_hint="${AWS_REGION:-us-east-2}"

cat <<EOF

Ready in ${dir}.

Create a cluster (this is the command that asks before it spends money):

  cd ${dir}
  export CLUSTER_NAME=${cluster_hint}
  export AWS_REGION=${region_hint}
  ./infra/scripts/distai-up.sh

Then every chapter starts with these four lines, and needs nothing else. The region is one of them
because a cluster is identified by account, region and name: with it unset, the AWS CLI's own default
region decides where the cluster is looked for, and a default that differs from the cluster's is a
lookup that fails.

  cd ${dir}
  export CLUSTER_NAME=${cluster_hint}
  export AWS_REGION=${region_hint}
  source infra/scripts/distai-env.sh
EOF
