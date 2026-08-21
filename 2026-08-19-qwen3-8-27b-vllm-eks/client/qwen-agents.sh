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
#   ./agents.sh push <file> [agent]     copy a local image/video into the agent pod (for multimodal)
#   ./agents.sh down                    stop background port-forwards started by this script
#
# Multimodal: the agents read files from the POD filesystem and base64-embed them into the request
# (no upload API). `push` kubectl-cp's a local file into the pod (default agent: qwen-code) and, for
# video, ffmpeg-downsamples it first (vLLM samples only a few frames, so shrinking client-side is
# faster). It prints the pod path; reference it in the TUI, e.g. qwen-code: `@/root/media/foo.png`.
# Images work today (verified); video support is weak/uneven across the CLIs (see docs).
#
# Arg passthrough: everything after the agent name is forwarded verbatim to the wrapped CLI, e.g.
#   ./agents.sh qwen-code -r <session-id>          # resume a Qwen Code session
#   ./agents.sh qwen-code -p "summarize this repo"  # non-interactive prompt
#   ./agents.sh opencode  run "fix the failing test"
# Shell-only (-t / --shell) drops you at a bash prompt in the pod for manual work:
#   ./agents.sh -t qwen-code
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# An env file next to the launcher is OPTIONAL. If present it is sourced first; otherwise every
# value comes from QWEN_* environment variables, and the context defaults to the current kubeconfig
# context. Only `setup` needs CLUSTER_NAME/REGION; the exec/push/openclaw paths need just a context.
ENV_FILE="${AGENTS_ENV:-$HERE/agents.env}"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi
[ -z "${AWS_PROFILE:-}" ] && unset AWS_PROFILE || true
KUBE_CONTEXT="${KUBE_CONTEXT:-${QWEN_KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}}"
NAMESPACE="${NAMESPACE:-${QWEN_NAMESPACE:-qwen}}"
# derive region from the context's EKS cluster ARN (arn:aws:eks:<region>:...) so no env is needed
_CTX_CLUSTER="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$KUBE_CONTEXT')].context.cluster}" 2>/dev/null || true)"
REGION="${REGION:-${QWEN_REGION:-$(printf '%s' "$_CTX_CLUSTER" | sed -n 's#^arn:aws:eks:\([^:]*\):.*#\1#p')}}"
REGION="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo ap-northeast-1)}}}"
: "${KUBE_CONTEXT:?no kube context available — set QWEN_KUBE_CONTEXT or select one with kubectl}"
PROFILE_ARGS=(); [ -n "${AWS_PROFILE:-}" ] && PROFILE_ARGS=(--profile "$AWS_PROFILE")
K=(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE")
PFDIR="${TMPDIR:-/tmp}/agents-pf"; mkdir -p "$PFDIR"

cmd_setup() {
  CLUSTER_NAME="${CLUSTER_NAME:-${QWEN_CLUSTER_NAME:-}}"
  : "${CLUSTER_NAME:?setup needs a cluster name — set CLUSTER_NAME or QWEN_CLUSTER_NAME}"
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
  { command -v open >/dev/null 2>&1 && open "$url"; } 2>/dev/null \
    || { command -v xdg-open >/dev/null 2>&1 && xdg-open "$url"; } 2>/dev/null || true
}

cmd_down() {
  for pidf in "$PFDIR"/*.pid; do [ -f "$pidf" ] || continue; kill "$(cat "$pidf")" 2>/dev/null || true; rm -f "$pidf"; done
  echo "[OK] background port-forwards stopped"
}

# push a local image/video into the agent pod for multimodal use
cmd_push() {
  local src="${1:?usage: push <local-file> [opencode|qwen-code|hermes]}"; local agent="${2:-qwen-code}"
  [ -f "$src" ] || { echo "[NG] not a file: $src" >&2; exit 1; }
  local dep; dep="$(_deploy_for "$agent")"; [ -n "$dep" ] || { echo "[NG] unknown agent: $agent" >&2; exit 1; }
  local pod; pod="$("${K[@]}" get pod -l "app=$dep" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
  [ -n "$pod" ] || { echo "[NG] no running pod for $agent" >&2; exit 1; }
  local base; base="$(basename "$src")"; local send="$src"
  case "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" in
    *.mp4|*.mov|*.mkv|*.webm|*.avi)
      if command -v ffmpeg >/dev/null 2>&1; then
        local tmp="${TMPDIR:-/tmp}/agents-media"; mkdir -p "$tmp"; local out="$tmp/${base%.*}_ds.mp4"
        echo "[..] ffmpeg downsample (fps 1, <=512px, first 60s, no audio)..."
        if ffmpeg -y -i "$src" -vf "fps=1,scale='min(512,iw)':-2" -t 60 -an "$out" >/dev/null 2>&1; then
          send="$out"; base="$(basename "$out")"
        else echo "[warn] ffmpeg failed; sending the raw video"; fi
      else echo "[warn] ffmpeg not found locally; sending raw video (large; most frames dropped by the server)"; fi ;;
  esac
  local dest="${MEDIA_DIR:-/root/media}"
  "${K[@]}" exec "deploy/$dep" -- mkdir -p "$dest" >/dev/null 2>&1 || true
  echo "[..] copying $send -> $agent pod ($pod):$dest/$base"
  "${K[@]}" cp "$send" "$pod:$dest/$base"
  echo "[OK] pod path: $dest/$base"
  echo "     reference it in the TUI:"
  echo "       qwen-code:  @$dest/$base"
  echo "       opencode :  paste the path $dest/$base (or drag the local file if running opencode locally)"
}

usage() {
  local me; me="$(basename "$0")"
  cat >&2 <<USAGE
$me — launchers for the EKS-hosted Qwen3.8-27B agents (keyless kubectl exec)
  $me setup                      create the kubeconfig context (idempotent)
  $me opencode|hermes|qwen-code  exec into the pod and launch the CLI (extra args are forwarded)
  $me -t <agent>                 open a pod shell instead of the TUI
  $me openclaw                   background port-forward + open the OpenClaw Control UI
  $me push <file> [agent]        copy a local image/video into the agent pod (default: qwen-code)
  $me down                       stop background port-forwards
Env: QWEN_KUBE_CONTEXT (default current), QWEN_NAMESPACE (default qwen); region from the EKS ARN.
USAGE
}

# leading -t/--shell => log into the pod shell only, no TUI launch
SHELL_ONLY=0
if [ "${1:-}" = "-t" ] || [ "${1:-}" = "--shell" ]; then SHELL_ONLY=1; shift; fi

case "${1:-}" in
  setup) cmd_setup ;;
  opencode|hermes|qwen-code) agent="$1"; shift; _run_agent "$agent" "$@" ;;
  # back-compat: `shell <agent>` == `-t <agent>`
  shell) shift; SHELL_ONLY=1; _run_agent "${1:?usage: shell <opencode|hermes|qwen-code>}" ;;
  openclaw) cmd_openclaw ;;
  push) shift; cmd_push "$@" ;;
  down) cmd_down ;;
  *) usage; exit 1 ;;
esac
