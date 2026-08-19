#!/usr/bin/env bash
# agents.sh — one-shot launchers for the EKS-hosted agents (self-hosted Qwen3.8-27B backend).
#
# Keyless: uses `kubectl exec` (authenticated by your existing kubeconfig / AWS creds) to drop
# into the pods — no ssh key, no sshd, no port-forward for the shell agents. Only OpenClaw's
# browser UI uses a background port-forward.
#
# Self-contained: put this script + agents.env anywhere on your Mac. Prereqs: kubectl, aws CLI,
# curl, python3, and active AWS credentials. No repo checkout needed.
#
#   ./agents.sh setup                   one-time: create the kubeconfig context (idempotent)
#   ./agents.sh opencode  [args...]     exec into the opencode pod and launch opencode
#   ./agents.sh hermes    [args...]     exec into the hermes pod and launch hermes
#   ./agents.sh qwen-code [args...]     exec into the qwen-code pod and launch qwen (Qwen Code)
#   ./agents.sh -t <agent>              log into the pod with a shell and STOP (no TUI launch)
#   ./agents.sh openclaw                background port-forward + open the OpenClaw Control UI
#   ./agents.sh down                    stop background port-forwards started by this script
#
# Arg passthrough: everything after the agent name is forwarded verbatim to the wrapped CLI, e.g.
#   ./agents.sh qwen-code -r <session-id>          # resume a Qwen Code session
#   ./agents.sh qwen-code -p "summarize this repo"  # non-interactive prompt
#   ./agents.sh opencode  run "fix the failing test"
# Shell-only (-t / --shell) drops you at a bash prompt in the pod for manual work:
#   ./agents.sh -t qwen-code
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${AGENTS_ENV:-$HERE/agents.env}"
[ -f "$ENV_FILE" ] || { echo "[NG] $ENV_FILE not found. Copy agents.env.example -> agents.env and edit it." >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
[ -z "${AWS_PROFILE:-}" ] && unset AWS_PROFILE || true
: "${CLUSTER_NAME:?}"; : "${REGION:?}"; : "${KUBE_CONTEXT:?}"; : "${NAMESPACE:?}"
PROFILE_ARGS=(); [ -n "${AWS_PROFILE:-}" ] && PROFILE_ARGS=(--profile "$AWS_PROFILE")
K=(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE")
PFDIR="${TMPDIR:-/tmp}/agents-pf"; mkdir -p "$PFDIR"

cmd_setup() {
  echo "[..] kubeconfig context $KUBE_CONTEXT"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" "${PROFILE_ARGS[@]}" --alias "$KUBE_CONTEXT" >/dev/null
  # remove the old ssh-based block if a previous version of this script installed one
  local cfg="$HOME/.ssh/config"
  if [ -f "$cfg" ] && grep -q ">>> eks-agents" "$cfg" 2>/dev/null; then
    local tmp; tmp="$(mktemp)"
    awk '/# >>> eks-agents/{p=1} !p{print} /# <<< eks-agents/{p=0}' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
    echo "[..] removed obsolete ssh Host block from ~/.ssh/config (no longer needed)"
  fi
  echo "[OK] setup done. Now:  ./agents.sh opencode | hermes | qwen-code | openclaw"
}

_deploy_for() { case "$1" in
  opencode)  echo "${OPENCODE_DEPLOY:-opencode}";;
  hermes)    echo "${HERMES_DEPLOY:-hermes}";;
  qwen-code) echo "${QWENCODE_DEPLOY:-qwen-code}";;
  *) echo "";; esac; }

# per-agent: how to cd + the CLI binary to exec
_cd_for()  { case "$1" in hermes) echo 'cd /opt/data/work 2>/dev/null || cd ~';; *) echo 'cd ~';; esac; }
_bin_for() { case "$1" in opencode) echo opencode;; hermes) echo hermes;; qwen-code) echo qwen;; esac; }

_exec() {  # _exec <deploy> <command-string>
  local dep="$1"; shift
  exec "${K[@]}" exec -it "deploy/$dep" -- bash -lc "$*"
}

# _run_agent <agent> [passthrough args...]
_run_agent() {
  local agent="$1"; shift || true
  local dep; dep="$(_deploy_for "$agent")"
  [ -n "$dep" ] || { echo "[NG] unknown agent: $agent  (use opencode | hermes | qwen-code)" >&2; exit 1; }
  local cd_cmd; cd_cmd="$(_cd_for "$agent")"
  if [ "${SHELL_ONLY:-0}" = 1 ]; then
    _exec "$dep" "$cd_cmd; exec bash"
  fi
  local bin; bin="$(_bin_for "$agent")"
  # forward passthrough args verbatim, safely re-quoted for the remote shell
  local extra="" a
  for a in "$@"; do extra+=" $(printf '%q' "$a")"; done
  _exec "$dep" "$cd_cmd; exec $bin$extra"
}

cmd_openclaw() {
  local pidf="$PFDIR/openclaw.pid"
  if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then :; else
    "${K[@]}" port-forward "svc/${OPENCLAW_SVC:-openclaw}" "${OPENCLAW_PORT:-18789}:${OPENCLAW_PORT:-18789}" >"$PFDIR/openclaw.log" 2>&1 &
    echo $! > "$pidf"
  fi
  local port="${OPENCLAW_PORT:-18789}"
  for _ in $(seq 1 30); do curl -sf -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null && break; sleep 0.4; done
  local url="http://127.0.0.1:${port}/#token=${OPENCLAW_TOKEN:-qwen-demo-token}"
  echo "[OK] OpenClaw Control UI: $url  (port-forward in background; ./agents.sh down to stop)"
  open "$url" 2>/dev/null || true
}

cmd_down() {
  for pidf in "$PFDIR"/*.pid; do [ -f "$pidf" ] || continue; kill "$(cat "$pidf")" 2>/dev/null || true; rm -f "$pidf"; done
  echo "[OK] background port-forwards stopped"
}

usage() { sed -n '2,25p' "$HERE/$(basename "${BASH_SOURCE[0]}")"; }

# leading -t/--shell => log into the pod shell only, no TUI launch
SHELL_ONLY=0
if [ "${1:-}" = "-t" ] || [ "${1:-}" = "--shell" ]; then SHELL_ONLY=1; shift; fi

case "${1:-}" in
  setup) cmd_setup ;;
  opencode|hermes|qwen-code) agent="$1"; shift; _run_agent "$agent" "$@" ;;
  # back-compat: `shell <agent>` == `-t <agent>`
  shell) shift; SHELL_ONLY=1; _run_agent "${1:?usage: shell <opencode|hermes|qwen-code>}" ;;
  openclaw) cmd_openclaw ;;
  down) cmd_down ;;
  *) usage; exit 1 ;;
esac
