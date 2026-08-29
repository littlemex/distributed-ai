#!/usr/bin/env bash
# Repo-hygiene lint for this reference. Run before committing / publishing.
#   ./scripts/lint.sh
# Checks: no environment-specific values (account id, cluster/context names) leaked into tracked
# files; shellcheck on the shell entrypoints; yamllint on the plain-YAML manifests (NOT the Helm
# chart templates, which are Go templates and not valid YAML).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1
rc=0

echo "[lint] env-specific values"
# 12-digit AWS account ids, and any cluster/context names that must not ship in a public reference.
# Extend CLUSTER_PAT with the names this deployment happens to use before publishing.
# A 12-digit AWS account id, but only when it is a standalone token — not a 12-digit run that happens
# to sit inside a longer alphanumeric string such as a commit SHA. Real account ids appear delimited
# by :/./quote/space (ARNs, ECR hosts), which this still catches.
ACCOUNT_PAT='(^|[^0-9A-Za-z])[0-9]{12}([^0-9A-Za-z]|$)'
# Set LINT_FORBID to a regex of this deployment's cluster/context names before publishing.
CLUSTER_PAT="${LINT_FORBID:-}"
PAT="$ACCOUNT_PAT"; [ -n "$CLUSTER_PAT" ] && PAT="$ACCOUNT_PAT|$CLUSTER_PAT"
if grep -rInE "$PAT" --exclude=lint.sh \
     --include='*.md' --include='*.yaml' --include='*.yml' --include='*.json' \
     --include='*.sh' --include='*.py' --include='*.env' --include='*.example' . ; then
  echo "[lint][FAIL] environment-specific value found above — parameterize it"; rc=1
else
  echo "[lint][ok] none found"
fi

echo "[lint] shellcheck"
SH=(scripts/deploy.sh scripts/lint.sh client/qwen-agents.sh client/port-forward.sh serving/sglang/image/build.sh)
present=0
for f in "${SH[@]}"; do [ -f "$f" ] || continue; present=1
  command -v shellcheck >/dev/null 2>&1 && { shellcheck -x --severity=error "$f" || rc=1; } || echo "[lint][skip] shellcheck not installed"
done
[ "$present" = 1 ] || { echo "[lint][FAIL] no shell scripts matched — check paths"; rc=1; }

echo "[lint] yamllint (manifests only, not Helm templates)"
# read into an array without mapfile (mapfile is bash 4+, absent on macOS's bash 3.2)
YAMLS=()
while IFS= read -r y; do YAMLS+=("$y"); done < <(find serving/sglang/manifests serving/pool serving/values serving/alias-*.yaml agents experiments \
     -name '*.yaml' -not -path '*/charts/*/templates/*' 2>/dev/null)
if [ "${#YAMLS[@]}" -eq 0 ]; then echo "[lint][FAIL] no manifests matched — check paths"; rc=1
elif command -v yamllint >/dev/null 2>&1; then yamllint "${YAMLS[@]}" || rc=1
else echo "[lint][skip] yamllint not installed (${#YAMLS[@]} files would be checked)"; fi

[ "$rc" = 0 ] && echo "[lint] PASS" || echo "[lint] FAIL"
exit "$rc"
