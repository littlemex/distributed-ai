#!/usr/bin/env bash
# Run the pilot: every policy against every instance in the subset, and collect the results.
#
#   export KUBE_CONTEXT=<context>  STRATOCLAVE_HOST=<host>  STRATOCLAVE_API_KEY=<token>
#   export STRATOCLAVE_DEFAULTS=<gateway repo>/backend/mvp/defaults
#   export QWEN_LOCAL_ENDPOINT_URL=<self-hosted /v1/chat/completions>   # capacity-first only
#   ./sweep.sh
#
# Instance-major rather than policy-major: the five episodes for one instance share a 1.0-1.3
# GB image, and a row of the results table is only useful complete. Two instances are in
# flight at a time, so ten Jobs, which is what the gateway and the node disks tolerate.
#
# Resumable, because a run of this size will be interrupted: an (instance, policy) pair whose
# score.json is already on the shared volume is skipped. Delete the directory to redo one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${NAMESPACE:-swe-pilot}"
SUBSET="${SUBSET:-${HERE}/pilot-subset.json}"
POLICIES="${POLICIES:-premium-always cheap-always cheap-then-escalate capacity-first role-based}"
IN_FLIGHT="${IN_FLIGHT:-2}"
RESULTS="${RESULTS:-$(cd "${HERE}/.." && pwd)/results/episodes}"
# A repeat pass writes one level deeper on the volume, so this is where its episodes land
# locally once collect.sh has copied the volume down.
PASS_DIR="${PASS:+pass${PASS}/}"
: "${KUBE_CONTEXT:?set KUBE_CONTEXT to the target cluster}"
KC="kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE}"

# One collect up front: it creates the reader pod, and the local copy is what decides which
# pairs are already done. Cheaper than asking the volume once per pair.
"${HERE}/collect.sh" "${RESULTS}" >/dev/null
echo "[INFO] resuming against $(find "${RESULTS}" -name score.json 2>/dev/null | wc -l | tr -d ' ') episodes already scored"

INSTANCES=()
while IFS= read -r line; do
  INSTANCES+=("${line}")
done < <(python3 -c "
import json
print('\n'.join(json.load(open('${SUBSET}'))))
")
echo "[INFO] ${#INSTANCES[@]} instances x $(echo ${POLICIES} | wc -w | tr -d ' ') policies, ${IN_FLIGHT} instances in flight"

job_name() {
  # Mirrors run.sh, which needs a DNS label.
  local safe; safe="$(echo "$1" | tr '[:upper:]_' '[:lower:]-')"
  local name="ep-${safe}-$(echo "$2" | tr -d '[:space:]')"
  echo "${name:0:57}${PASS:+-p${PASS}}"
}

# An episode that ended on the transport rather than on the policy is worth one more try:
# nothing about the arm was observed, and leaving it there costs the paired comparison a whole
# row. An episode excluded for any other pre-registered reason stands as it is.
already_done() {
  local directory="${RESULTS}/${PASS_DIR}$1/$2"
  if [[ -n "${SCORE_ONLY:-}" ]]; then
    # Rescoring: the work to redo is every pair that has a diff, and nothing else. A pair with
    # no diff has no episode to score, whatever its score.json says.
    [[ -f "${directory}/diff.patch" ]] && return 1
    return 0
  fi
  [[ -f "${directory}/score.json" ]] || return 1
  python3 - "${directory}/episode.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)
episode = json.loads(path.read_text())
why = episode.get("not_comparable_because") or ""
raise SystemExit(1 if "transport" in why else 0)
PY
}

launch_instance() {
  local instance="$1" launched=0
  for policy in ${POLICIES}; do
    if already_done "${instance}" "${policy}"; then
      continue
    fi
    "${HERE}/run.sh" "${instance}" "${policy}" >/dev/null 2>&1 || {
      echo "[FAIL] could not submit ${instance} / ${policy}"
      continue
    }
    launched=$((launched + 1))
  done
  echo "[INFO] ${instance}: ${launched} episodes submitted"
}

# Waits for every Job named after these instances to stop being active, whichever way it
# stopped. An image that does not exist is not worth forty minutes of waiting, so a pod stuck
# pulling is given up on and its Job deleted.
wait_for() {
  local deadline=$((SECONDS + ${EPISODE_TIMEOUT:-3600}))
  while :; do
    local active=0
    for instance in "$@"; do
      for policy in ${POLICIES}; do
        local job; job="$(job_name "${instance}" "${policy}")"
        local status
        status="$($KC get job "${job}" -o jsonpath='{.status.conditions[*].type} {.status.active}' 2>/dev/null || true)"
        [[ -z "${status}" ]] && continue
        if [[ "${status}" == *Complete* || "${status}" == *Failed* ]]; then
          continue
        fi
        local stuck
        stuck="$($KC get pods -l "job-name=${job}" \
          -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null || true)"
        if [[ "${stuck}" == *ImagePull* || "${stuck}" == *ErrImage* ]]; then
          echo "[FAIL] ${job}: image will not pull (${stuck}), giving up on it"
          $KC delete job "${job}" --ignore-not-found >/dev/null
          continue
        fi
        active=$((active + 1))
      done
    done
    [[ "${active}" -eq 0 ]] && return 0
    if [[ "${SECONDS}" -gt "${deadline}" ]]; then
      echo "[WARN] ${active} episodes still running after ${EPISODE_TIMEOUT:-3600}s; moving on"
      return 0
    fi
    sleep 20
  done
}

# A gateway that has run out of credit answers every request the same way, and a sweep that
# keeps going pulls a hundred more images to write a hundred more episodes that end on the same
# wall. Checked per instance rather than per episode: one 402 can be a per-model quota, but a
# whole instance ending that way is the account.
credit_wall() {
  local instance="$1" walled=0 seen=0
  for policy in ${POLICIES}; do
    local episode="${RESULTS}/${PASS_DIR}${instance}/${policy}/episode.json"
    [[ -f "${episode}" ]] || continue
    seen=$((seen + 1))
    grep -q "credit_exhausted" "${episode}" && walled=$((walled + 1))
  done
  [[ "${seen}" -gt 0 && "${walled}" -eq "${seen}" ]]
}

batch=()
for instance in "${INSTANCES[@]}"; do
  launch_instance "${instance}"
  batch+=("${instance}")
  if [[ "${#batch[@]}" -ge "${IN_FLIGHT}" ]]; then
    wait_for "${batch[@]}"
    "${HERE}/collect.sh" "${RESULTS}" | tail -8
    for done_instance in "${batch[@]}"; do
      if credit_wall "${done_instance}"; then
        echo "[FAIL] every episode of ${done_instance} ended on exhausted credit; stopping here"
        echo "       raise the budget and re-run: the sweep skips what is already scored"
        exit 1
      fi
    done
    batch=()
  fi
done
if [[ "${#batch[@]}" -gt 0 ]]; then
  wait_for "${batch[@]}"
fi

echo "[INFO] sweep finished"
"${HERE}/collect.sh" "${RESULTS}"
