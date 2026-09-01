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
#   check-release-pin.sh --list-files    print the files that carry the release name, one per line, so
#                                        that the tool which bumps them cannot drift from this list.
#
# Exit: 0 agree, 1 disagree, 2 cannot tell (a file or tool is missing, or the argument is not a
# release), 3 nothing to compare against.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${here}/../.." && pwd)"
VERSION='v[0-9]+\.[0-9]+\.[0-9]+'
TAG_PREFIX='release/eks-distributed-ai'
RAW='https://raw\.githubusercontent\.com/littlemex/distributed-ai/refs/tags'

die() { printf 'check-release-pin: %s\n' "$*" >&2; exit 2; }
no()  { printf 'check-release-pin: %s\n' "$*" >&2; exit 1; }

# Every place the release name is written, as (file, anchored extractor). Anchoring each one to the
# line it belongs on is the point: a free grep for the pattern passes when the pin is deleted and only
# a prose mention survives, and it cannot tell a stale copy left beside a fresh one. Each site must
# appear exactly once, and every site must agree.
#   pin  — decides what gets cloned
#   url  — a URL a reader copies; naming another release sends them to another tree
#   cd   — the directory those URLs land in, derived from the pin
SITES=(
  "infra/scripts/distai-install.sh##pin##^PIN_DEFAULT=\"(${TAG_PREFIX}/${VERSION})\"$"
  "infra/scripts/get-profiling.sh##pin##^PIN_DEFAULT=\"(${TAG_PREFIX}/${VERSION})\"$"
  "infra/scripts/get-profiling.sh##url##^#   curl -fsSL ${RAW}/(${TAG_PREFIX}/${VERSION})/infra/scripts/get-profiling\.sh \| bash$"
  "infra/docs/profiling-install.md##url##^curl -fsSL ${RAW}/(${TAG_PREFIX}/${VERSION})/infra/scripts/get-profiling\.sh \| bash$"
  "infra/docs/profiling-install.md##cd##^cd ~/distributed-ai-(${VERSION})$"
)
# Files allowed to name a release without being a site: this script and the tooling around it explain
# the invariant, and the tests exercise it. A release name appearing anywhere else is a new publishing
# path that nobody taught the bump about, which is the drift this check exists to notice.
ALLOWED_ELSEWHERE=(
  "infra/scripts/check-release-pin.sh"
  "infra/scripts/cut-release.sh"
  ".github/workflows/release-pin.yml"
  "infra/eks/tests/cases/registry.sh"
)

site_files() { printf '%s\n' "${SITES[@]}" | cut -d'#' -f1 | sort -u; }

if [ "${1:-}" = "--list-files" ]; then
  [ $# -eq 1 ] || die "--list-files takes no other argument"
  site_files
  exit 0
fi
[ $# -le 1 ] || die "takes at most one release; got $#"

# --- what the tree says -------------------------------------------------------------------------
pin=""
for site in "${SITES[@]}"; do
  f="${site%%##*}"; rest="${site#*##}"; kind="${rest%%##*}"; re="${rest#*##}"
  [ -f "${root}/${f}" ] || die "${f} is missing; this check is looking in the wrong place"
  # The line is selected by the anchored pattern, so a value with anything after it (v0.2.1-bad) does
  # not match the site at all and is reported as a missing site rather than silently truncated.
  lines="$(grep -E "${re}" "${root}/${f}" || true)"
  n="$(printf '%s' "${lines}" | grep -c . || true)"
  if [ "${n}" != "1" ]; then
    no "${f}: expected exactly one ${kind} line naming a release, found ${n}"
  fi
  v="$(printf '%s' "${lines}" | grep -oE "${TAG_PREFIX}/${VERSION}" | head -1 || true)"
  if [ -z "${v}" ]; then
    v="${TAG_PREFIX}/$(printf '%s' "${lines}" | grep -oE "${VERSION}" | head -1)"
  fi
  if [ -n "${pin}" ] && [ "${v}" != "${pin}" ]; then
    no "the release name disagrees inside the tree: ${pin} and ${v} (${f}, ${kind})"
  fi
  pin="${v}"
done
[ -n "${pin}" ] || die "no sites were checked; the table is empty"

# A release name outside the sites is a publishing path the bump does not know about.
if command -v git >/dev/null && git -C "${root}" rev-parse --git-dir >/dev/null 2>&1; then
  known="$( { site_files; printf '%s\n' "${ALLOWED_ELSEWHERE[@]}"; } | sort -u)"
  stray="$(git -C "${root}" grep -lE "${TAG_PREFIX}/${VERSION}" -- . 2>/dev/null | sort -u | comm -23 - <(printf '%s\n' "${known}") || true)"
  [ -z "${stray}" ] || no "these files name a release but nothing bumps them: $(printf '%s' "${stray}" | tr '\n' ' ')"
fi

# --- what it should be --------------------------------------------------------------------------
want="${1:-}"
if [ -z "${want}" ]; then
  command -v git >/dev/null || die "git is not available and no release was named"
  git -C "${root}" rev-parse --git-dir >/dev/null 2>&1 || die "not a git checkout and no release was named"
  # --points-at rather than describe: describe picks one tag when several point at the same commit, so
  # a stale-but-matching tag beside a fresh wrong one would pass. Here, several is ambiguous and says so.
  mapfile -t tags < <(git -C "${root}" tag --points-at HEAD --list "${TAG_PREFIX}/v*") ||
    die "git could not list the tags at HEAD"
  case "${#tags[@]}" in
    0) printf 'check-release-pin: HEAD carries no release tag; nothing to compare the pin against\n' >&2; exit 3 ;;
    1) want="${tags[0]}" ;;
    *) die "HEAD carries several release tags (${tags[*]}); name the one to check" ;;
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
