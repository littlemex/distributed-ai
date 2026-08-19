#!/usr/bin/env bash
# agents.sh — one-shot launchers for the EKS-hosted agents (self-hosted Qwen3.8-27B backend).
#
# Self-contained: put this script + agents.env anywhere on your Mac. Prereqs are only the
# standard tools (kubectl, aws CLI, ssh, nc). No repo checkout needed.
#
#   ./agents.sh setup      one-time: kubeconfig + ssh key (auto-created & synced) + ~/.ssh/config
#   ssh opencode           ssh straight into the opencode pod (port-forward runs automatically)
#   ./agents.sh opencode    ssh in AND launch the opencode TUI
#   ./agents.sh hermes      ssh in AND launch hermes (if the hermes pod is deployed)
#   ./agents.sh openclaw    background port-forward + open the OpenClaw Control UI in your browser
#   ./agents.sh down        stop background port-forwards started by this script
#   ./agents.sh proxy <deploy>   (internal) ssh ProxyCommand; you don't call this directly
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${AGENTS_ENV:-$HERE/agents.env}"
[ -f "$ENV_FILE" ] || { echo "[NG] $ENV_FILE not found. Copy agents.env.example -> agents.env and edit it." >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${CLUSTER_NAME:?}"; : "${REGION:?}"; : "${KUBE_CONTEXT:?}"; : "${NAMESPACE:?}"; : "${SSH_KEY:?}"
[ -z "${AWS_PROFILE:-}" ] && unset AWS_PROFILE || true
PROFILE_ARGS=(); [ -n "${AWS_PROFILE:-}" ] && PROFILE_ARGS=(--profile "$AWS_PROFILE")
K=(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE")
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
PFDIR="${TMPDIR:-/tmp}/agents-pf"; mkdir -p "$PFDIR"

_free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
_pod() { "${K[@]}" get pods -l "app=$1" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

cmd_setup() {
  echo "[..] kubeconfig context $KUBE_CONTEXT"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" "${PROFILE_ARGS[@]}" --alias "$KUBE_CONTEXT" >/dev/null
  # ssh key: create if missing
  if [ ! -f "$SSH_KEY" ]; then
    echo "[..] creating ssh key $SSH_KEY"
    mkdir -p "$(dirname "$SSH_KEY")"; ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "eks-agents" >/dev/null
  fi
  local pub; pub="$(cat "$SSH_KEY.pub")"
  # sync public key into each pod's Secret if changed, then restart that deploy
  for pair in "opencode-ssh:$OPENCODE_DEPLOY" "hermes-ssh:${HERMES_DEPLOY:-}"; do
    local secret="${pair%%:*}" deploy="${pair##*:}"; [ -n "$deploy" ] || continue
    "${K[@]}" get deploy "$deploy" >/dev/null 2>&1 || continue
    local cur; cur="$("${K[@]}" get secret "$secret" -o jsonpath='{.data.authorized_keys}' 2>/dev/null | python3 -c 'import sys,base64;sys.stdout.write(base64.b64decode(sys.stdin.read() or "").decode() )' 2>/dev/null || true)"
    if [ "$cur" != "$pub" ]; then
      echo "[..] syncing ssh key into $secret + restarting $deploy"
      "${K[@]}" create secret generic "$secret" --from-file=authorized_keys=<(printf '%s\n' "$pub") --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
      "${K[@]}" rollout restart "deploy/$deploy" >/dev/null
    fi
  done
  # ~/.ssh/config entries (idempotent, delimited block)
  local cfg="$HOME/.ssh/config"; mkdir -p "$HOME/.ssh"; touch "$cfg"
  local begin="# >>> eks-agents (agents.sh) >>>" end="# <<< eks-agents (agents.sh) <<<"
  local tmp; tmp="$(mktemp)"; awk -v b="$begin" -v e="$end" 'BEGIN{p=1} $0==b{p=0} p{print} $0==e{p=1}' "$cfg" > "$tmp"
  { cat "$tmp"; cat <<EOF
$begin
Host opencode hermes
  HostName localhost
  User root
  IdentityFile $SSH_KEY
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  ProxyCommand $SELF proxy %n
$end
EOF
  } > "$cfg.new" && mv "$cfg.new" "$cfg"; rm -f "$tmp"
  echo "[OK] setup done. Now:  ssh opencode   (or ./agents.sh openclaw)"
}

cmd_proxy() {  # ssh ProxyCommand: %h is 'opencode' or 'hermes'
  local host="$1" deploy
  case "$host" in
    opencode) deploy="$OPENCODE_DEPLOY" ;;
    hermes)   deploy="${HERMES_DEPLOY:?hermes not configured}" ;;
    *) echo "unknown host $host" >&2; exit 1 ;;
  esac
  local pod; pod="$(_pod "$deploy")"; [ -n "$pod" ] || { echo "no running pod for $deploy" >&2; exit 1; }
  local lp; lp="$(_free_port)"
  "${K[@]}" port-forward "pod/$pod" "$lp:22" >/dev/null 2>&1 &
  local pf=$!; trap 'kill $pf 2>/dev/null' EXIT
  for _ in $(seq 1 50); do nc -z localhost "$lp" 2>/dev/null && break; sleep 0.2; done
  exec nc localhost "$lp"
}

cmd_opencode() { exec ssh -t opencode 'opencode'; }
cmd_hermes()   { exec ssh -t hermes 'hermes'; }

cmd_openclaw() {
  local pidf="$PFDIR/openclaw.pid"
  if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then :; else
    "${K[@]}" port-forward "svc/${OPENCLAW_SVC}" "${OPENCLAW_PORT}:${OPENCLAW_PORT}" >"$PFDIR/openclaw.log" 2>&1 &
    echo $! > "$pidf"
  fi
  for _ in $(seq 1 30); do curl -sf -o /dev/null "http://127.0.0.1:${OPENCLAW_PORT}/" 2>/dev/null && break; sleep 0.4; done
  local url="http://127.0.0.1:${OPENCLAW_PORT}/#token=${OPENCLAW_TOKEN}"
  echo "[OK] OpenClaw Control UI: $url  (port-forward running in background; ./agents.sh down to stop)"
  open "$url" 2>/dev/null || true
}

cmd_down() {
  for pidf in "$PFDIR"/*.pid; do [ -f "$pidf" ] || continue; kill "$(cat "$pidf")" 2>/dev/null || true; rm -f "$pidf"; done
  echo "[OK] background port-forwards stopped"
}

case "${1:-}" in
  setup) cmd_setup ;;
  proxy) shift; cmd_proxy "$@" ;;
  opencode) cmd_opencode ;;
  hermes) cmd_hermes ;;
  openclaw) cmd_openclaw ;;
  down) cmd_down ;;
  *) sed -n '2,20p' "$SELF"; exit 1 ;;
esac
