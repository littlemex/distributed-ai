#!/usr/bin/env bash
# cut-release.sh — the paved way to cut a release, so the pin can never be left behind.
#
# A release is two things that have to agree: a tag, and the release name written inside the tree that
# tag points at. Doing it by hand means remembering the second one, and the one time it was forgotten
# the published URL installed a different release than it named. This script is the only path that
# cannot forget, because it bumps first and refuses to tag a commit whose pin disagrees.
#
# It is deliberately two commands, because main is reached through review here:
#
#   cut-release.sh prepare v0.2.2     bump every copy of the release name on a branch, verify, push it.
#                                     Open the pull request and merge it as usual.
#   cut-release.sh tag v0.2.2         after that merge: verify origin/main carries this release's pin,
#                                     then tag that commit and push the tag.
#
# `tag` re-checks rather than trusting `prepare`, because between them a human merged something.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${here}/../.." && pwd)"
check="${here}/check-release-pin.sh"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,${/^[^#]/q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

[ $# -ge 1 ] || usage 1
cmd="$1"; shift
case "${cmd}" in -h|--help|help) usage ;; esac
[ $# -eq 1 ] || die "${cmd} takes exactly one version, like v0.2.2"
ver="$1"
case "${ver}" in v[0-9]*.[0-9]*.[0-9]*) ;; *) die "version must look like v0.2.2, got ${ver}" ;; esac
tag="release/eks-distributed-ai/${ver}"
[ -x "${check}" ] || die "${check#"${root}"/} is missing or not executable"

git -C "${root}" rev-parse --git-dir >/dev/null 2>&1 || die "not a git checkout"

case "${cmd}" in
prepare)
  [ -z "$(git -C "${root}" status --porcelain -- infra)" ] ||
    die "infra has uncommitted changes; commit or stash them first"
  git -C "${root}" fetch -q origin
  git -C "${root}" ls-remote --exit-code --tags origin "${tag}" >/dev/null 2>&1 &&
    die "${tag} already exists on the remote; pick the next version"
  branch="release/prepare-${ver}"
  say "branching ${branch} from origin/main"
  git -C "${root}" switch -q -C "${branch}" origin/main

  say "bumping every copy of the release name to ${ver}"
  # Both installers and the doc, in one pass: the pins that decide what gets cloned, the URLs a reader
  # copies, and the directory those URLs land in.
  local_files=(infra/scripts/distai-install.sh infra/scripts/get-profiling.sh infra/docs/profiling-install.md)
  ( cd "${root}" && perl -pi -e "s{release/eks-distributed-ai/v[0-9]+\.[0-9]+\.[0-9]+}{${tag}}g" "${local_files[@]}" )
  ( cd "${root}" && perl -pi -e "s{distributed-ai-v[0-9]+\.[0-9]+\.[0-9]+}{distributed-ai-${ver}}g" infra/docs/profiling-install.md )

  say "verifying"
  "${check}" "${ver}"

  git -C "${root}" add -- "${local_files[@]}"
  git -C "${root}" diff --cached --quiet && die "nothing changed; the pin was already ${ver}"
  git -C "${root}" commit -q -m "release: pin ${ver}

Cutting ${tag} means the tree that tag points at has to name that release: the
installers write the pin out rather than derive it, so a copy fetched from
anywhere installs one known tree."
  git -C "${root}" push -q -u origin "${branch}"
  say "pushed ${branch}. Merge it, then: cut-release.sh tag ${ver}"
  ;;
tag)
  git -C "${root}" fetch -q origin
  git -C "${root}" ls-remote --exit-code --tags origin "${tag}" >/dev/null 2>&1 &&
    die "${tag} already exists on the remote; moving a published tag changes the tree under anyone who has it"
  say "checking that origin/main carries the pin for ${ver}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  # Read the files out of origin/main rather than the working tree, so an unmerged local edit cannot
  # make this pass. The check script needs the repository layout, so lay those paths out under tmp.
  for f in infra/scripts/distai-install.sh infra/scripts/get-profiling.sh infra/docs/profiling-install.md infra/scripts/check-release-pin.sh; do
    mkdir -p "${tmp}/$(dirname "${f}")"
    git -C "${root}" show "origin/main:${f}" >"${tmp}/${f}" || die "origin/main has no ${f}"
  done
  chmod +x "${tmp}/infra/scripts/check-release-pin.sh"
  "${tmp}/infra/scripts/check-release-pin.sh" "${ver}"
  say "tagging origin/main ($(git -C "${root}" rev-parse --short origin/main))"
  git -C "${root}" tag -a "${tag}" origin/main -m "eks-distributed-ai ${ver}"
  git -C "${root}" push -q origin "${tag}"
  say "pushed ${tag}. The book's install URL and its cd path both follow ${ver}."
  ;;
*) usage 1 ;;
esac
