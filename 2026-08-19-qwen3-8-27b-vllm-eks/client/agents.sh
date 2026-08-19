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
#   ./agents.sh setup       one-time: create the kubeconfig context (idempotent)
#   ./agents.sh opencode     exec into the opencode pod and launch the opencode TUI
#   ./agents.sh hermes       exec into the hermes pod and launch the hermes TUI
#   ./agents.sh shell <name> exec a bash shell in a pod (name: opencode | hermes)
#   ./agents.sh openclaw     background port-forward + open the OpenClaw Control UI in the browser
#   ./agents.sh down         stop background port-forwards started by this script
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
  echo "[OK] setup done. Now:  ./agents.sh opencode   |   ./agents.sh hermes   |   ./agents.sh openclaw"
}

_deploy_for() { case "$1" in opencode) echo "${OPENCODE_DEPLOY:-opencode}";; hermes) echo "${HERMES_DEPLOY:-hermes}";; *) echo "" ;; esac; }

_exec() {  # _exec <deploy> <command...>
  local dep="$1"; shift
  exec "${K[@]}" exec -it "deploy/$dep" -- bash -lc "$*"
}

cmd_opencode() { _exec "$(_deploy_for opencode)" 'cd ~ && exec opencode'; }
cmd_hermes()   { _exec "$(_deploy_for hermes)"   'cd /opt/data/work 2>/dev/null || cd ~; exec hermes'; }
cmd_shell()    { local d; d="$(_deploy_for "${1:?usage: shell <opencode|hermes>}")"; [ -n "$d" ] || { echo "unknown $1" >&2; exit 1; }; _exec "$d" 'exec bash'; }

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

case "${1:-}" in
  setup) cmd_setup ;;
  opencode) cmd_opencode ;;
  hermes) cmd_hermes ;;
  shell) shift; cmd_shell "$@" ;;
  openclaw) cmd_openclaw ;;
  down) cmd_down ;;
  *) sed -n '2,20p' "$HERE/$(basename "${BASH_SOURCE[0]}")"; exit 1 ;;
esac
