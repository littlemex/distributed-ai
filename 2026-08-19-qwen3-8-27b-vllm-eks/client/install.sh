#!/usr/bin/env bash
# One-shot installer. Fetches this reference at a pinned ref, deploys the stack, installs the `qa`
# launcher onto PATH, and adds ~/.local/bin to PATH if missing. No git clone, no manual steps.
#
#   curl -fsSL <commit-pinned-raw-url>/client/install.sh | bash -s -- [deploy flags...]
#   curl -fsSL <commit-pinned-raw-url>/client/install.sh | bash -s -- --websearch --only serving
#   curl -fsSL <commit-pinned-raw-url>/client/install.sh | bash -s -- --no-deploy   # launcher only
#
# All deploy flags (--engine, --only, --websearch, --yes, --skip-smoke) are forwarded to deploy.sh.
# Installer flags: --ref <sha|branch> (default: pin at release), --no-deploy (install the launcher
# only). The only env you may set: QWEN_NAMESPACE (default qwen), QWEN_KUBE_CONTEXT (default current
# context). Region and cluster are auto-derived from the context's EKS ARN. Repo coordinates default
# to this project: override with QWEN_REPO / QWEN_REF; a private repo needs GITHUB_TOKEN.
set -euo pipefail

REPO="${QWEN_REPO:-littlemex/distributed-ai}"
REF="${QWEN_REF:-main}"
SUBDIR="${QWEN_DIR:-2026-08-19-qwen3-8-27b-vllm-eks}"
DO_DEPLOY=1
PASS=()
while [ $# -gt 0 ]; do case "$1" in
  --ref) REF="${2:?}"; shift 2;;
  --no-deploy) DO_DEPLOY=0; shift;;
  *) PASS+=("$1"); shift;;
esac; done

say(){ printf '\n\033[1;32m[install]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[install][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

for c in curl tar kubectl; do command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"; done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
say "fetching $REPO@$REF"
AUTH=(); [ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
curl -fsSL "${AUTH[@]+"${AUTH[@]}"}" "https://codeload.github.com/$REPO/tar.gz/$REF" | tar -xz -C "$TMP" \
  || die "download/extract failed — private repo needs GITHUB_TOKEN, or set QWEN_REF to a valid ref"
SRC=""; for d in "$TMP"/*/"$SUBDIR"; do [ -d "$d" ] && SRC="$d"; done
[ -n "$SRC" ] || die "subdir $SUBDIR not found in $REPO@$REF"

if [ "$DO_DEPLOY" = 1 ]; then
  say "deploying${PASS[0]+ (flags: ${PASS[*]})}"
  # keep deploy.sh's confirm prompt usable under curl|bash by reading from the terminal; if there is
  # no terminal (headless), auto-confirm so the one-shot still completes.
  if [ -e /dev/tty ]; then ( cd "$SRC" && ./scripts/deploy.sh "${PASS[@]+"${PASS[@]}"}" ) </dev/tty
  else ( cd "$SRC" && ./scripts/deploy.sh "${PASS[@]+"${PASS[@]}"}" --yes ); fi
fi

say "installing launcher -> ~/.local/bin/qwen-agents (+ qa)"
mkdir -p "$HOME/.local/bin"
install -m 755 "$SRC/client/qwen-agents.sh" "$HOME/.local/bin/qwen-agents"
ln -sf "$HOME/.local/bin/qwen-agents" "$HOME/.local/bin/qa"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) : ;;
  *)
    case "$(basename "${SHELL:-sh}")" in
      zsh)  rc="$HOME/.zshrc";;
      bash) rc="$HOME/.bashrc";;
      *)    rc="$HOME/.profile";;
    esac
    line='export PATH="$HOME/.local/bin:$PATH"'
    grep -qF "$line" "$rc" 2>/dev/null || printf '\n%s\n' "$line" >> "$rc"
    export PATH="$HOME/.local/bin:$PATH"
    say "added ~/.local/bin to PATH in $rc — open a new terminal or run: exec \"\$SHELL\" -l"
    ;;
esac

say "done. launch an agent:  qa opencode    (also: qa qwen-code | hermes | openclaw)"
