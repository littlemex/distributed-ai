#!/usr/bin/env bash
# Generic JSON task execution engine. Runs on the target node.
#
# A task file is JSON:
#
#   {
#     "name": "human readable name",
#     "tasks": [
#       {
#         "id": "01-example",
#         "name": "Example step",
#         "skip_if": "test -f /etc/example.conf",
#         "allow_failure": false,
#         "commands": ["echo one", "echo two"]
#       }
#     ]
#   }
#
# "skip_if" makes a step idempotent: when the shell expression succeeds the step is
# skipped. "allow_failure" records a non-zero exit status and continues, which is what a
# negative control needs.
#
# Usage: sudo ./task_runner.sh tasks/<file>.json

set -uo pipefail

TASK_FILE="${1:?usage: task_runner.sh <task-file.json>}"
LOG_DIR="${LOG_DIR:-/var/log/task-runner}"
mkdir -p "${LOG_DIR}"

task_name=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' "${TASK_FILE}")
task_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["tasks"]))' "${TASK_FILE}")

echo "[RUNNER] task file: ${TASK_FILE}"
echo "[RUNNER] name: ${task_name}"
echo "[RUNNER] steps: ${task_count}"

failures=0
for index in $(seq 0 $((task_count - 1))); do
    read -r step_id step_name allow_failure < <(python3 - "${TASK_FILE}" "${index}" <<'PY'
import json
import sys

step = json.load(open(sys.argv[1]))["tasks"][int(sys.argv[2])]
print(step["id"], step.get("name", step["id"]).replace(" ", "_"), str(step.get("allow_failure", False)).lower())
PY
    )
    skip_if=$(python3 - "${TASK_FILE}" "${index}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1]))["tasks"][int(sys.argv[2])].get("skip_if", ""))
PY
    )
    script=$(python3 - "${TASK_FILE}" "${index}" <<'PY'
import json
import sys

step = json.load(open(sys.argv[1]))["tasks"][int(sys.argv[2])]
print("\n".join(step["commands"]))
PY
    )

    echo "[STEP ${step_id}] ${step_name//_/ }"
    if [[ -n "${skip_if}" ]] && bash -c "${skip_if}" >/dev/null 2>&1; then
        echo "[STEP ${step_id}] skipped (skip_if satisfied)"
        continue
    fi

    log="${LOG_DIR}/${step_id}.log"
    if bash -o pipefail -c "set -x; ${script}" >"${log}" 2>&1; then
        status=0
    else
        status=$?
    fi
    cat "${log}"
    if [[ ${status} -ne 0 ]]; then
        if [[ "${allow_failure}" == "true" ]]; then
            echo "[STEP ${step_id}] exit ${status} (allow_failure)"
        else
            echo "[STEP ${step_id}] FAILED exit ${status}"
            failures=$((failures + 1))
            break
        fi
    else
        echo "[STEP ${step_id}] ok"
    fi
done

if [[ ${failures} -eq 0 ]]; then
    echo "[RUNNER] result: ok"
else
    echo "[RUNNER] result: failed"
fi
exit ${failures}
