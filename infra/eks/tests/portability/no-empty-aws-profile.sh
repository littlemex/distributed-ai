#!/usr/bin/env bash
# no-empty-aws-profile.sh — an exported-but-empty AWS_PROFILE must never reach the AWS CLI.
#
# `export AWS_PROFILE=` does not mean "no profile" to the CLI. It looks for a profile whose name is the
# empty string, finds none, and fails — and what it prints is usually about credentials or the resource
# being read rather than about the empty string, so the symptom lands far from the cause. Measured:
# sourcing distai-env.sh that way ended in "cannot read the registry at /distai/v1/clusters/... in
# us-east-2" and left `k` as a bare alias, while the same shell with the variable unset succeeded. This
# has cost real debugging time three separate times, most recently from a test that interpolated
# AWS_PROFILE='${AWS_PROFILE_OPT:-}' and so sent an empty string on every run that chose no profile.
#
# Two rules, and both have to hold:
#   1. No file may write one of the known shapes of an empty profile: an empty literal, a default of
#      nothing, an empty --profile. This is a rule about text. Whether some variable happens to be empty
#      at runtime is not decidable here, and this check does not claim it is — runtime emptiness is the
#      second rule's job.
#   2. Every script a reader runs or sources must turn an empty AWS_PROFILE back into an unset one,
#      before it invokes anything, so that a shell which already has one cannot poison it. The guard is
#      required by exact text, at column zero, outside any heredoc, and above the first invocation.
#      Each of those conditions exists because without it a guard that never runs still passes.
#
# AWS_DEFAULT_PROFILE gets the same treatment: the v1 CLI and boto3 read it, so an empty one is the same
# defect wearing another name, and leaving it out would be waiting for the fourth occurrence.
#
# Known limits, so that a green run is not read as more than it is. Rule 1 is line-oriented and literal:
# a value assembled at runtime (`AWS_PROFILE="$x"`), a continuation across two lines, and a CI
# expression that expands to nothing are all invisible to it. Rule 2 sees `aws` and friends only when
# they are named literally; a path held in a variable is not matched. And the guard only protects paths
# that go through these scripts — a reader who exports an empty profile and then runs terraform or a
# boto3 program directly is outside what any of this can reach.
#
# Exit: 0 both rules hold, 1 one of them does not, 2 the check cannot run (which is never a pass).
set -euo pipefail

die() { printf '%s\n' "$*" >&2; exit 2; }

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${here}/../../../.." && pwd)"
cd "${root}"
command -v git >/dev/null || die "git is required: this check scans the tree"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  die "${root} is not a git work tree, so the tree-wide scan cannot run"
command -v awk >/dev/null || die "awk is required: the guard's position is checked with it"
[ -f infra/scripts/distai-env.sh ] ||
  die "cannot find infra/scripts/distai-env.sh under ${root}; this check is looking in the wrong place"

GUARD_PROFILE='[ -n "${AWS_PROFILE:-}" ] || unset AWS_PROFILE'
GUARD_DEFAULT='[ -n "${AWS_DEFAULT_PROFILE:-}" ] || unset AWS_DEFAULT_PROFILE'
# A tool whose SDK reads AWS_PROFILE. The word must stand alone, and a leading path is allowed so that
# /usr/bin/aws counts; a name held in a variable cannot be seen and is named as a limit in the header.
TOOL_RE='(^|[^A-Za-z0-9_.-])(/[^ \t]*/)?(aws|terraform|kubectl|helm|eksctl)([ \t;&|)]|$)'
fails=0

# Which scripts have to carry the guard. Enumerated from the directories rather than listed, so that a
# ninth reader-facing script is covered the day it is added instead of the day someone remembers this
# file. Anything genuinely exempt is named below with its reason, and the exemption is checked too.
#   check-release-pin.sh, cut-release.sh — maintainer tools that touch git and nothing in AWS.
EXEMPT="infra/scripts/check-release-pin.sh infra/scripts/cut-release.sh"
guarded=""
for f in infra/scripts/*.sh infra/eks/bin/kubectl-* infra/eks/tests/run-tests.sh; do
  [ -f "${f}" ] || continue
  case " ${EXEMPT} " in *" ${f} "*) continue ;; esac
  guarded="${guarded} ${f}"
done
n_guarded="$(printf '%s\n' ${guarded} | wc -l | tr -d ' ')"
# A lower bound, not just "more than zero". Enumeration solves the problem of a new script being missed
# and creates the opposite one: if a directory is renamed or the kubectl-* convention changes, the globs
# match less and the check stays green over a shrinking set. Changing this number is the point at which
# someone has to say out loud that a script no longer needs the guard.
[ "${n_guarded}" -ge 9 ] ||
  die "only ${n_guarded} scripts matched the enumeration (expected at least 9); the globs are stale"

# The position check. awk rather than grep because three things have to be true at once, and because a
# heredoc body has to be skipped: its lines can sit at column zero and never run, which would let a
# script that generates another script pass by quoting the guard into a template.
guard_report() {
  awk -v gp="${GUARD_PROFILE}" -v gd="${GUARD_DEFAULT}" -v tool="${TOOL_RE}" '
    function strip(s) { sub(/^[ \t]+/, "", s); return s }
    BEGIN { lp = 0; ld = 0; use = 0; hd = "" }
    {
      # Inside a heredoc: nothing here is code. <<- lets the terminator be indented with tabs.
      if (hd != "") {
        t = $0; sub(/^\t+/, "", t)
        if (t == hd) hd = ""
        next
      }
      if (match($0, /<<-?[ \t]*['"'"'"]?[A-Za-z_][A-Za-z_0-9]*['"'"'"]?/)) {
        tag = substr($0, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*/, "", tag)
        gsub(/['"'"'"]/, "", tag)
        hd = tag
        # The opening line is still code, so it falls through to the checks below.
      }
      if ($0 == gp && lp == 0) lp = NR
      if ($0 == gd && ld == 0) ld = NR
      if (use == 0 && strip($0) !~ /^#/ && $0 ~ tool) use = NR
    }
    END {
      bad = 0
      if (lp == 0) { print "has no unindented, non-heredoc line that normalises an empty AWS_PROFILE"; bad = 1 }
      if (ld == 0) { print "has no unindented, non-heredoc line that normalises an empty AWS_DEFAULT_PROFILE"; bad = 1 }
      if (bad == 0 && use > 0 && (lp > use || ld > use)) {
        printf "guards are at lines %d and %d but a tool that reads the variable is invoked at line %d\n", lp, ld, use
        bad = 1
      }
      exit bad
    }' "$1"
}
for f in ${guarded}; do
  rc=0
  out="$(guard_report "${f}")" || rc=$?
  case "${rc}" in
    0) ;;
    1) printf '%s: %s\n  add both lines near the top, before anything is invoked:\n    %s\n    %s\n' \
         "${f}" "${out}" "${GUARD_PROFILE}" "${GUARD_DEFAULT}" >&2
       fails=$((fails + 1)) ;;
    *) die "awk failed while checking ${f} (exit ${rc}): ${out}" ;;
  esac
done

# The tree-wide half of rule 1. No pathspec: a shape this cheap to write can appear in a Makefile, a
# Dockerfile, a composite action or a script with no extension, and scanning only *.sh would be a rule
# that covers the places someone thought of. -I skips binaries. --untracked reaches files that are not
# committed yet; it does not reach ignored ones, so a personal .envrc is out of scope here and the guard
# is what covers that case. Whole-line comments are dropped so a line explaining the rule does not trip
# it; a trailing comment on a code line is not, because that is where a disabled-but-copied command hides.
#
# These two files contain the banned shapes deliberately: one is this check, the other is its runtime twin.
SELF='infra/eks/tests/portability/no-empty-aws-profile\.sh|infra/eks/tests/portability/empty-profile-behaviour\.sh'
scan() {
  local label="$1" pattern="$2" raw="" out="" rc=0
  raw="$(git grep -I --untracked -nE -e "${pattern}" -- . 2>/dev/null)" || rc=$?
  case "${rc}" in
    0) ;;
    1) return 0 ;;
    *) die "git grep failed while scanning for ${label} (exit ${rc}); rerun it by hand to see why" ;;
  esac
  # Each filter's own failure has to stay distinguishable from "it matched nothing", which is why the
  # result is built up step by step instead of one pipeline ending in `|| true`.
  out="$(printf '%s\n' "${raw}" | { grep -vE ':[0-9]+:[[:space:]]*#' || [ $? = 1 ]; })" ||
    die "the comment filter failed while scanning for ${label}"
  out="$(printf '%s\n' "${out}" | { grep -vE "^(${SELF}):" || [ $? = 1 ]; })" ||
    die "the self filter failed while scanning for ${label}"
  out="$(printf '%s' "${out}" | sed '/^$/d')"
  [ -z "${out}" ] || { printf '%s:\n%s\n' "${label}" "${out}" >&2; fails=$((fails + 1)); }
}

# An empty literal, in every spelling: `AWS_PROFILE=`, `export AWS_PROFILE=`, `AWS_PROFILE=""`,
# `AWS_PROFILE=''`, and the same with a separator or end of line after the `=`. The bare form is the
# original of this defect, and the first version of this check did not look for it.
scan "assigns an empty AWS_PROFILE" 'AWS_(DEFAULT_)?PROFILE=([[:space:];&|)]|$|""|'"''"')'
# A default that is nothing: ${x:-}, ${x-}, ${x:-""}. This is the shape that bit us — "no profile
# chosen" silently becomes "a profile named nothing".
scan "assigns AWS_PROFILE from a default that can be empty" \
  'AWS_(DEFAULT_)?PROFILE=["'"'"']?\$\{[A-Za-z_][A-Za-z_0-9]*:?-(""|'"''"')?\}'
# --profile with nothing after it, space-separated or with an equals sign, which the CLI also accepts.
scan "passes an empty --profile" '\-\-profile([[:space:]]+|[[:space:]]*=[[:space:]]*)(""|'"''"')'
scan "passes --profile with nothing after it" '\-\-profile=([[:space:];&|)]|$)'
scan "passes --profile a default that can be empty" \
  '\-\-profile([[:space:]]+|[[:space:]]*=[[:space:]]*)["'"'"']?\$\{[A-Za-z_][A-Za-z_0-9]*:?-(""|'"''"')?\}'
# The same thing where env is written as a mapping rather than an assignment: YAML (workflows, manifests,
# compose) and JSON (devcontainer, task definitions, editor settings).
scan "sets an empty AWS_PROFILE in YAML" \
  'AWS_(DEFAULT_)?PROFILE:[[:space:]]*(""|'"''"'|~|null)?[[:space:]]*(#|$)'
scan "sets an empty AWS_PROFILE in JSON" 'AWS_(DEFAULT_)?PROFILE"[[:space:]]*:[[:space:]]*""'

# The exemptions have to keep being true. A maintainer tool that grows an aws call is no longer exempt,
# and the quiet version of that is the one to catch: nothing else would notice.
for f in ${EXEMPT}; do
  [ -f "${f}" ] || { printf 'exempt file %s no longer exists; drop it from EXEMPT\n' "${f}" >&2; fails=$((fails + 1)); continue; }
  if grep -vE '^[[:space:]]*#' "${f}" | grep -qE "${TOOL_RE}"; then
    printf '%s is exempt because it does not touch AWS, but it now invokes one of the tools; remove the exemption and add the guard\n' \
      "${f}" >&2
    fails=$((fails + 1))
  fi
done

[ "${fails}" -eq 0 ] || {
  printf '\n%s problem(s). An empty AWS_PROFILE fails far from where it was set; see the header of %s.\n' \
    "${fails}" "infra/eks/tests/portability/no-empty-aws-profile.sh" >&2
  exit 1
}
printf 'none of the known empty-profile shapes appear in the tree, and all %s reader-facing scripts neutralise one first\n' \
  "${n_guarded}"
