#!/usr/bin/env bash
# no-modern-bash.sh — refuse constructs a reader's bash may not have.
#
# Apple ships bash 3.2 as /bin/bash and does not update it, so `#!/usr/bin/env bash` resolves to 3.2 on
# a stock Mac. Anything newer than that is a script that works for the author and not for the reader.
# The failures are quiet: measured on 3.2.57, `mapfile` leaves the array empty and execution continues,
# so the symptom appears later and somewhere else. `bash -n` does not catch it either, because these are
# builtins looked up when they run. Hence a list.
#
# 04-teardown.sh reads with a while loop and says why; cut-release.sh used mapfile and would have failed
# on a Mac. This is that comment turned into something that fails the build.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${here}/../../../.." && pwd)"
cd "${root}"

# Files a reader runs, or sources, on their own machine.
files=""
for f in infra/scripts/*.sh infra/eks/bin/kubectl-* infra/eks/scripts/*.sh; do
  [ -f "${f}" ] && files="${files} ${f}"
done
[ -n "${files}" ] || { printf 'no-modern-bash: found no scripts to check; wrong directory?\n' >&2; exit 2; }

# Each entry is a construct that arrived after 3.2, with the version that brought it. Comments are
# stripped first so that a line explaining why something is avoided does not count as using it.
fails=0
check() {
  local since="$1" pattern="$2" hits=""
  hits="$(grep -nE "${pattern}" ${files} 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  [ -z "${hits}" ] || {
    printf 'needs bash %s or newer:\n%s\n' "${since}" "${hits}" >&2
    fails=$((fails + 1))
  }
}
check 4.0 '(^|[^[:alnum:]_])(mapfile|readarray)[[:space:]]'
check 4.0 'declare[[:space:]]+-A|local[[:space:]]+-A'
check 4.0 '\$\{[A-Za-z_][A-Za-z_0-9]*(\[[^]]*\])?(,,|\^\^)'
check 4.0 'shopt[[:space:]]+-s[[:space:]]+globstar'
check 4.0 '(^|[^[:alnum:]_])coproc[[:space:]]'
check 4.2 '\[\[[[:space:]]+-v[[:space:]]'
check 4.3 '(^|[^[:alnum:]_])local[[:space:]]+-n[[:space:]]|(^|[^[:alnum:]_])declare[[:space:]]+-n[[:space:]]'
check 4.3 'wait[[:space:]]+-n'
check 4.4 '\$\{[A-Za-z_][A-Za-z_0-9]*@[QEPAa]\}'
# 5.2 gave '&' in a replacement the meaning "the matched text". Either meaning is a trap, because which
# one applies is decided by the reader's bash, so the construct is banned where its replacement could
# contain one — not the substitution itself, which is everywhere and harmless with a plain replacement.
check 5.2 '\$\{[A-Za-z_][A-Za-z_0-9]*//[^}]*/[^}]*&[^}]*\}'

[ "${fails}" -eq 0 ] || { printf '\n%s construct(s) a reader may not have. See infra/eks/tests/portability/no-modern-bash.sh for why.\n' "${fails}" >&2; exit 1; }
printf 'no reader-facing script needs a bash newer than 3.2\n'
