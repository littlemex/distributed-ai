#!/usr/bin/env bash
# Deploy and run JSON tasks on an EC2 instance through AWS Systems Manager.
#
# The instance under test lives in a private subnet and is reached over SSM, so no
# inbound access and no SSH key are needed. Every command executed on the node comes
# from a JSON task definition in tasks/, executed by setup/task_runner.sh.
#
# Usage:
#   export INSTANCE_ID=i-0123456789abcdef0
#   export AWS_REGION=<region>
#   ./runner.sh deploy
#   ./runner.sh run tasks/01-install-target-kernel.json
#   ./runner.sh run tasks/05-mount-and-io.json --env FSX_DNS_NAME=... --env FSX_MOUNT_NAME=...
#   ./runner.sh wait                      # wait for the node to come back after a reboot
#   ./runner.sh logs 06                   # read back a step log from the node
#
# Options:
#   --instance-id <id>   overrides INSTANCE_ID
#   --env K=V            passed to the task as an environment variable; repeatable
#   --timeout <seconds>  command completion timeout (default 1800)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/opt/task-runner}"
TIMEOUT="${TIMEOUT:-1800}"
INSTANCE_ID="${INSTANCE_ID:-}"
ENV_ARGS=()

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
}

require_instance() {
    if [[ -z "${INSTANCE_ID}" ]]; then
        echo "error: INSTANCE_ID is not set" >&2
        exit 1
    fi
}

send() {
    # send <shell script text> -> prints the command output.
    # Systems Manager writes the payload to a file and executes it, so the shebang
    # selects bash; the default shell on the node is dash and does not accept pipefail.
    local script
    script="#!/bin/bash
$1"
    local command_id
    command_id=$(aws ssm send-command \
        --instance-ids "${INSTANCE_ID}" \
        --document-name AWS-RunShellScript \
        --comment "task-runner" \
        --timeout-seconds 3600 \
        --parameters "$(python3 -c '
import json
import sys

print(json.dumps({"commands": [sys.stdin.read()], "executionTimeout": [sys.argv[1]]}))
' "${TIMEOUT}" <<<"${script}")" \
        --query Command.CommandId --output text)

    local status=""
    local waited=0
    while true; do
        status=$(aws ssm get-command-invocation \
            --command-id "${command_id}" --instance-id "${INSTANCE_ID}" \
            --query Status --output text 2>/dev/null || echo Pending)
        case "${status}" in
            Success | Failed | Cancelled | TimedOut | Undeliverable | Terminated) break ;;
        esac
        if [[ ${waited} -ge ${TIMEOUT} ]]; then
            echo "error: command ${command_id} did not finish within ${TIMEOUT}s" >&2
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done

    aws ssm get-command-invocation \
        --command-id "${command_id}" --instance-id "${INSTANCE_ID}" \
        --query 'StandardOutputContent' --output text
    local stderr
    stderr=$(aws ssm get-command-invocation \
        --command-id "${command_id}" --instance-id "${INSTANCE_ID}" \
        --query 'StandardErrorContent' --output text)
    if [[ -n "${stderr}" && "${stderr}" != "None" ]]; then
        echo "--- stderr ---"
        echo "${stderr}"
    fi
    echo "--- ssm status: ${status} (command ${command_id}) ---"
    [[ "${status}" == "Success" ]]
}

cmd_deploy() {
    require_instance
    local bundle
    # COPYFILE_DISABLE keeps macOS from adding AppleDouble ._ members to the archive.
    bundle=$(cd "${HERE}" && COPYFILE_DISABLE=1 tar --exclude '._*' -czf - task_runner.sh tasks | base64 | tr -d '\n')
    send "set -euo pipefail
mkdir -p '${REMOTE_DIR}'
echo '${bundle}' | base64 -d | tar -xzf - -C '${REMOTE_DIR}'
chmod +x '${REMOTE_DIR}/task_runner.sh'
ls -la '${REMOTE_DIR}' '${REMOTE_DIR}/tasks'"
}

cmd_run() {
    require_instance
    local task_file="$1"
    shift || true
    local exports=""
    for pair in "${ENV_ARGS[@]:-}"; do
        [[ -z "${pair}" ]] && continue
        exports+="export ${pair%%=*}='${pair#*=}'
"
    done
    local remote_task="${REMOTE_DIR}/$(basename "$(dirname "${task_file}")")/$(basename "${task_file}")"
    send "set -uo pipefail
${exports}cd '${REMOTE_DIR}'
bash '${REMOTE_DIR}/task_runner.sh' '${remote_task}'"
}

cmd_logs() {
    # Systems Manager truncates command output, so long tasks are read back per step from
    # the node, where task_runner.sh keeps one log file per step.
    require_instance
    local pattern="${1:-}"
    send "set -uo pipefail
for log in /var/log/task-runner/${pattern}*.log; do
    [ -e \"\${log}\" ] || continue
    echo \"===== \${log} =====\"
    cat \"\${log}\"
done"
}

cmd_wait() {
    require_instance
    local waited=0
    while [[ ${waited} -lt ${TIMEOUT} ]]; do
        local ping
        ping=$(aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
            --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)
        if [[ "${ping}" == "Online" ]]; then
            echo "instance ${INSTANCE_ID} is Online after ${waited}s"
            return 0
        fi
        sleep 10
        waited=$((waited + 10))
    done
    echo "error: instance ${INSTANCE_ID} did not become Online within ${TIMEOUT}s" >&2
    return 1
}

SUBCOMMAND="${1:-}"
shift || usage
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-id) INSTANCE_ID="$2"; shift 2 ;;
        --env) ENV_ARGS+=("$2"); shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h | --help) usage ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

case "${SUBCOMMAND}" in
    deploy) cmd_deploy ;;
    run) cmd_run "${POSITIONAL[0]:?usage: runner.sh run tasks/<file>.json}" ;;
    wait) cmd_wait ;;
    logs) cmd_logs "${POSITIONAL[0]:-}" ;;
    *) usage ;;
esac
