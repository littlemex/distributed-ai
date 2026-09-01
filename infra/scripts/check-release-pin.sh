#!/usr/bin/env bash
# check-release-pin.sh — assert that the installers pin the release they are published under.
#
# The pin is written out in the installers rather than derived, so that a copy of a script fetched
# from anywhere still installs one known tree. That only holds if the commit a release tag points at
# carries that tag's own name. Nothing at runtime notices when it does not: the reader's URL names one
# release, the clone is another, and both look successful. It happened once — v0.2.1 was tagged without
# the bump, so the v0.2.1 URL cloned v0.2.0 — which is why this check exists as a script rather than as
# a step in someone's memory.
#
# Usage:
#   check-release-pin.sh                 compare against the tag HEAD is at; exit 3 when HEAD is not
#                                        at a release tag, since then there is nothing to compare
#   check-release-pin.sh <tag-or-version>  compare against a release named explicitly, for the moment
#                                        before the tag exists (cut-release.sh does this)
#
# Exit: 0 agree, 1 disagree, 2 cannot tell (missing file, no git), 3 no release to compare against.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${here}/../.." && pwd)"
PATTERN='release/eks-distributed-ai/v[0-9]+\.[0-9]+\.[0-9]+'

die() { printf 'check-release-pin: %s\n' "$*" >&2; exit 2; }

# Every place the release name is written. The first two are pins that decide what gets cloned; the
# rest are copies a reader follows, and a copy left behind sends them to another release's tree.
pin_files=("${root}/infra/scripts/distai-install.sh" "${root}/infra/scripts/get-profiling.sh")
echo_files=("${root}/infra/docs/profiling-install.md")

for f in "${pin_files[@]}" "${echo_files[@]}"; do
  [ -f "${f}" ] || die "${f#"${root}"/} is missing; this check is looking in the wrong place"
done

found="$(grep -rhoE "${PATTERN}" "${pin_files[@]}" "${echo_files[@]}" | sort -u)"
[ -n "${found}" ] || die "no release name found in the installers or the doc"
if [ "$(printf '%s\n' "${found}" | wc -l | tr -d ' ')" -ne 1 ]; then
  printf 'the release name disagrees between the installers and the doc: %s\n' \
    "$(printf '%s' "${found}" | tr '\n' ' ')" >&2
  exit 1
fi
pin="${found}"

want="${1:-}"
if [ -z "${want}" ]; then
  command -v git >/dev/null || die "git is not available and no release was named"
  git -C "${root}" rev-parse --git-dir >/dev/null 2>&1 || die "not a git checkout and no release was named"
  want="$(git -C "${root}" describe --exact-match --tags --match 'release/eks-distributed-ai/v*' HEAD 2>/dev/null || true)"
  [ -n "${want}" ] || { printf 'HEAD is not at a release tag; nothing to compare the pin against\n' >&2; exit 3; }
fi
# A bare version is accepted because that is what a human types when cutting a release.
case "${want}" in release/*) ;; v*) want="release/eks-distributed-ai/${want}" ;; *) want="release/eks-distributed-ai/v${want}" ;; esac

if [ "${pin}" != "${want}" ]; then
  printf 'the release is %s but the installers pin %s\n' "${want}" "${pin}" >&2
  printf 'bump it in the commit that gets tagged: infra/scripts/cut-release.sh prepare %s\n' "${want##*/}" >&2
  exit 1
fi

# The directory the installers clone into is derived from the pin, so a doc that cds elsewhere is
# a reader typing a path that does not exist.
ver="${pin##*/}"
grep -qF "cd ~/distributed-ai-${ver}" "${echo_files[0]}" || {
  printf '%s cds into a directory from another release (the pin is %s)\n' \
    "${echo_files[0]#"${root}"/}" "${ver}" >&2
  exit 1
}
printf 'release pin agrees: %s\n' "${pin}"
