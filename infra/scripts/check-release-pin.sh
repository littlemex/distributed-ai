#!/usr/bin/env bash
# check-release-pin.sh — assert that the installers pin the release they are published under.
#
# The pin is written out in the installers rather than derived, so that a copy of a script fetched from
# anywhere still installs one known tree. That only holds if the commit a release tag points at carries
# that tag's own name. Nothing at runtime notices when it does not: the reader's URL names one release,
# the clone is another, and both look successful. It happened once — a tag was cut without the bump, so
# the newer URL cloned the older tree — which is why this is a script rather than a step in someone's
# memory.
#
# Usage:
#   check-release-pin.sh                 compare against the release tag at HEAD. Exit 3 when HEAD
#                                        carries none, since then there is nothing to compare.
#   check-release-pin.sh <release>       compare against a release named explicitly: 0.2.2, v0.2.2 or
#                                        release/eks-distributed-ai/v0.2.2. CI passes the tag it was
#                                        triggered by, and cut-release.sh the one it is about to make,
#                                        so neither has to guess from the commit.
#   check-release-pin.sh --print-pin     print the release the tree names, having checked that every
#                                        site agrees and that no other file names one. Needs no tag, so
#                                        the tests can exercise all of that on every commit.
#   check-release-pin.sh --list-files    print the files that carry the release name, one per line, so
#                                        that the tool which bumps them cannot drift from this list.
#
# Exit: 0 agree, 1 disagree, 2 cannot tell (a file or tool is missing, or the argument is not a
# release), 3 nothing to compare against. Anything that cannot be classified is 2, never a pass.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${here}/../.." && pwd)"
VERSION='v[0-9]+\.[0-9]+\.[0-9]+'
TAG_PREFIX='release/eks-distributed-ai'
RAW='https://raw\.githubusercontent\.com/littlemex/distributed-ai/refs/tags'
SEP=$'\t'

die() { printf 'check-release-pin: %s\n' "$*" >&2; exit 2; }
no()  { printf 'check-release-pin: %s\n' "$*" >&2; exit 1; }
warn() { printf 'check-release-pin: warning: %s\n' "$*" >&2; }

for t in grep sort comm head printf; do command -v "${t}" >/dev/null || die "${t} is not available"; done

# Every place the release name is written, as file, kind and an anchored extractor. Anchoring each one
# to the line it belongs on is the point: a free grep for the pattern passes when the pin is deleted and
# only a prose mention survives, and it cannot tell a stale copy left beside a fresh one.
#   pin  — decides what gets cloned
#   url  — a URL a reader copies; naming another release sends them to another tree
#   cd   — the directory those URLs land in, derived from the pin
# Each site must appear exactly once and all of them must agree. The patterns are strict about the line
# they sit on, so reformatting one of these lines fails here rather than silently stopping the check.
SITES=(
  "infra/scripts/distai-install.sh${SEP}pin${SEP}^PIN_DEFAULT=\"(${TAG_PREFIX}/${VERSION})\"$"
  "infra/scripts/get-profiling.sh${SEP}pin${SEP}^PIN_DEFAULT=\"(${TAG_PREFIX}/${VERSION})\"$"
  "infra/scripts/get-profiling.sh${SEP}url${SEP}^#   curl -fsSL ${RAW}/(${TAG_PREFIX}/${VERSION})/infra/scripts/get-profiling\.sh \| bash$"
  "infra/docs/profiling-install.md${SEP}url${SEP}^curl -fsSL ${RAW}/(${TAG_PREFIX}/${VERSION})/infra/scripts/get-profiling\.sh \| bash$"
  "infra/docs/profiling-install.md${SEP}cd${SEP}^cd ~/distributed-ai-(${VERSION})$"
)
# Files allowed to name a release without being a site: the tooling that explains the invariant, and the
# test that exercises it. A release name anywhere else is a publishing path nobody taught the bump
# about — the drift this check exists to notice — so adding a line here rather than a site needs a
# reason, and the reason is that the file talks about releases instead of publishing one.
ALLOWED_ELSEWHERE=(
  "infra/scripts/check-release-pin.sh"
  "infra/scripts/cut-release.sh"
  ".github/workflows/release-pin.yml"
  "infra/eks/tests/cases/registry.sh"
)

site_field() { printf '%s' "$1" | cut -d"${SEP}" -f"$2"; }
site_files() { local s; for s in "${SITES[@]}"; do site_field "${s}" 1; done | LC_ALL=C sort -u; }

mode="check"
case "${1:-}" in
  --list-files) [ $# -eq 1 ] || die "--list-files takes no other argument"; site_files; exit 0 ;;
  --print-pin)  [ $# -eq 1 ] || die "--print-pin takes no other argument"; mode="print" ; shift ;;
  -h|--help)    sed -n '2,${/^[^#]/q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
[ $# -le 1 ] || die "takes at most one release; got $#"

# --- what the tree says -------------------------------------------------------------------------
pin=""
for site in "${SITES[@]}"; do
  f="$(site_field "${site}" 1)"; kind="$(site_field "${site}" 2)"; re="$(site_field "${site}" 3)"
  [ -f "${root}/${f}" ] || die "${f} is missing; this check is looking in the wrong place"
  lines=""; rc=0
  lines="$(grep -E "${re}" "${root}/${f}")" || rc=$?
  case "${rc}" in
    0|1) ;;
    *) die "grep failed on ${f} (exit ${rc})" ;;
  esac
  n=0; [ -z "${lines}" ] || n="$(printf '%s\n' "${lines}" | grep -c .)"
  [ "${n}" = "1" ] || no "${f}: expected exactly one ${kind} line naming a release, found ${n}"
  v="$(printf '%s' "${lines}" | grep -oE "${TAG_PREFIX}/${VERSION}" | head -1)" || v=""
  if [ -z "${v}" ]; then
    v="$(printf '%s' "${lines}" | grep -oE "${VERSION}" | head -1)" ||
      die "${f}: the ${kind} line matched but no version could be read from it"
    [ -n "${v}" ] || die "${f}: the ${kind} line matched but no version could be read from it"
    v="${TAG_PREFIX}/${v}"
  fi
  if [ -n "${pin}" ] && [ "${v}" != "${pin}" ]; then
    no "the release name disagrees inside the tree: ${pin} and ${v} (${f}, ${kind})"
  fi
  pin="${v}"
done
[ -n "${pin}" ] || die "no sites were checked; the table is empty"

# A release name outside the sites is a publishing path the bump does not know about. Both the full tag
# and the directory form count: the sites themselves prove that a release gets named both ways.
if command -v git >/dev/null && git -C "${root}" rev-parse --git-dir >/dev/null 2>&1; then
  for f in "${ALLOWED_ELSEWHERE[@]}"; do
    [ -e "${root}/${f}" ] || die "ALLOWED_ELSEWHERE names ${f}, which does not exist; the list has rotted"
  done
  scan_pattern="(${TAG_PREFIX}/${VERSION}|distributed-ai-${VERSION})"
  named=""; rc=0
  # --untracked so that a file added but not yet committed is checked too: writing a new installer and
  # then running this before `git add` is the natural order, and it would otherwise pass.
  named="$(git -C "${root}" grep --untracked -lE "${scan_pattern}" -- .)" || rc=$?
  case "${rc}" in
    0|1) ;;
    *) die "git grep failed while scanning for release names (exit ${rc})" ;;
  esac
  known="$( { site_files; printf '%s\n' "${ALLOWED_ELSEWHERE[@]}"; } | LC_ALL=C sort -u)"
  stray="$(printf '%s' "${named}" | grep -v '^$' | LC_ALL=C sort -u | comm -23 - <(printf '%s\n' "${known}"))" ||
    die "could not compare the scan against the known files"
  [ -z "${stray}" ] ||
    no "these files name a release but nothing bumps them: $(printf '%s' "${stray}" | tr '\n' ' ')"
else
  warn "not a git checkout, so the scan for release names outside the known files was skipped"
fi

if [ "${mode}" = "print" ]; then printf '%s\n' "${pin}"; exit 0; fi

# --- what it should be --------------------------------------------------------------------------
want="${1:-}"
if [ -z "${want}" ]; then
  command -v git >/dev/null || die "git is not available and no release was named"
  git -C "${root}" rev-parse --git-dir >/dev/null 2>&1 || die "not a git checkout and no release was named"
  # --points-at rather than describe: describe picks one tag when several point at the same commit, so a
  # stale-but-matching tag beside a fresh wrong one would pass. The command substitution carries git's
  # own failure, which a process substitution into mapfile would have swallowed as "no tags".
  tags=""
  tags="$(git -C "${root}" tag --points-at HEAD --list "${TAG_PREFIX}/v*")" ||
    die "git could not list the tags at HEAD"
  case "$(printf '%s' "${tags}" | grep -c . || true)" in
    0) printf 'check-release-pin: HEAD carries no release tag; nothing to compare the pin against\n' >&2; exit 3 ;;
    1) want="${tags}" ;;
    *) die "HEAD carries several release tags ($(printf '%s' "${tags}" | tr '\n' ' ')); name the one to check" ;;
  esac
else
  case "${want}" in
    "${TAG_PREFIX}"/*) ;;
    v*) want="${TAG_PREFIX}/${want}" ;;
    *)  want="${TAG_PREFIX}/v${want}" ;;
  esac
  printf '%s' "${want}" | grep -qE "^${TAG_PREFIX}/${VERSION}$" ||
    die "not a release: ${1}. Expected 0.2.2, v0.2.2 or ${TAG_PREFIX}/v0.2.2"
fi

[ "${pin}" = "${want}" ] ||
  no "the release is ${want} but the tree pins ${pin}; bump it in the commit that gets tagged: infra/scripts/cut-release.sh prepare ${want##*/}"
printf 'release pin agrees: %s\n' "${pin}"
