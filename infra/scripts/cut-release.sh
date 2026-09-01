#!/usr/bin/env bash
# cut-release.sh — the paved way to cut a release, so the pin cannot be left behind.
#
# A release is two things that have to agree: a tag, and the release name written inside the tree that
# tag points at. By hand that means remembering the second one, and the one time it was forgotten the
# published URL installed a different release than it named. This is the path that cannot forget: it
# bumps first, and refuses to tag a commit whose pin disagrees.
#
# Two commands, because main is reached through review here:
#
#   cut-release.sh prepare v0.2.2   bump every file that carries the release name, on a branch off
#                                   origin/main, verify, and push it. Open the pull request as usual.
#   cut-release.sh tag v0.2.2       after that merge: re-read those files out of origin/main, refuse
#                                   when the pin disagrees, then tag that commit and push the tag.
#
# `tag` re-checks rather than trusting `prepare`, because a human merged something in between, and it
# reads origin/main rather than the working tree so an unmerged local edit cannot make it pass.
#
# Which files carry the name is asked of check-release-pin.sh, not repeated here: a second list is a
# second thing to forget, which is the shape of the bug this exists to prevent.
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
# Anchored: a glob like v[0-9]*.[0-9]*.[0-9]* accepts v1foo.2bar.3baz, and that string would then be
# spliced into a perl program below.
[[ "${ver}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like v0.2.2, got ${ver}"
tag="release/eks-distributed-ai/${ver}"
[ -x "${check}" ] || die "${check#"${root}"/} is missing or not executable"
git -C "${root}" rev-parse --git-dir >/dev/null 2>&1 || die "not a git checkout"

# --exit-code returns 2 for "no such tag" and 128-ish for "could not reach origin". Treating every
# non-zero as absence would skip the guard whenever the network is down.
remote_has_tag() {
  local rc=0
  git -C "${root}" ls-remote --exit-code --tags origin "${tag}" >/dev/null 2>&1 || rc=$?
  case "${rc}" in
    0) return 0 ;;
    2) return 1 ;;
    *) die "cannot reach origin to check whether ${tag} exists (git exit ${rc})" ;;
  esac
}

case "${cmd}" in
prepare)
  [ -z "$(git -C "${root}" status --porcelain)" ] ||
    die "the checkout has uncommitted changes; commit or stash them first"
  git -C "${root}" fetch -q origin
  ! remote_has_tag || die "${tag} already exists on the remote; pick the next version"
  branch="release/prepare-${ver}"
  git -C "${root}" rev-parse --verify -q "refs/heads/${branch}" >/dev/null &&
    die "${branch} already exists locally; delete it or finish the release it belongs to"
  say "branching ${branch} from origin/main"
  git -C "${root}" switch -q -c "${branch}" origin/main

  say "bumping every file that carries the release name to ${ver}"
  mapfile -t files < <("${check}" --list-files) || die "could not ask which files carry the release name"
  [ "${#files[@]}" -gt 0 ] || die "check-release-pin.sh listed no files"
  # The new name goes through the environment rather than into the program text, so that no argument
  # can end up being read as perl.
  ( cd "${root}" && TAG="${tag}" VER="${ver}" perl -pi \
      -e 's{release/eks-distributed-ai/v[0-9]+\.[0-9]+\.[0-9]+}{$ENV{TAG}}g;' \
      -e 's{distributed-ai-v[0-9]+\.[0-9]+\.[0-9]+}{distributed-ai-$ENV{VER}}g;' "${files[@]}" )

  say "verifying"
  "${check}" "${ver}"

  git -C "${root}" add -- "${files[@]}"
  git -C "${root}" diff --cached --quiet && die "nothing changed; the pin was already ${ver}"
  git -C "${root}" commit -q -m "release: pin ${ver}

Cutting ${tag} means the tree that tag points at has to name that release: the
installers write the pin out rather than derive it, so that a copy fetched from
anywhere installs one known tree."
  git -C "${root}" push -q -u origin "${branch}"
  say "pushed ${branch}. Merge it, then: cut-release.sh tag ${ver}"
  ;;
tag)
  git -C "${root}" fetch -q origin
  ! remote_has_tag ||
    die "${tag} already exists on the remote; moving a published tag changes the tree under anyone who has it"
  say "checking that origin/main carries the pin for ${ver}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  # Read the files out of origin/main, and run that commit's own check, so that both the list of files
  # and the invariant come from what is about to be tagged rather than from this working tree.
  git -C "${root}" show "origin/main:infra/scripts/check-release-pin.sh" >"${tmp}/check.sh" ||
    die "origin/main has no infra/scripts/check-release-pin.sh"
  chmod +x "${tmp}/check.sh"
  mkdir -p "${tmp}/infra/scripts"
  install -m 755 "${tmp}/check.sh" "${tmp}/infra/scripts/check-release-pin.sh"
  mapfile -t files < <("${tmp}/infra/scripts/check-release-pin.sh" --list-files) ||
    die "could not ask origin/main which files carry the release name"
  for f in "${files[@]}"; do
    mkdir -p "${tmp}/$(dirname "${f}")"
    git -C "${root}" show "origin/main:${f}" >"${tmp}/${f}" || die "origin/main has no ${f}"
  done
  "${tmp}/infra/scripts/check-release-pin.sh" "${ver}"
  say "tagging origin/main ($(git -C "${root}" rev-parse --short origin/main))"
  git -C "${root}" tag -a "${tag}" origin/main -m "eks-distributed-ai ${ver}"
  git -C "${root}" push -q origin "${tag}"
  say "pushed ${tag}. The install URL and the directory it lands in both follow ${ver}."
  ;;
*) usage 1 ;;
esac
