#!/usr/bin/env bash
# One-shot installer. Fetches this reference, deploys the stack, installs the `qa` launcher onto
# PATH, and records the deploy target so `qa` targets the same cluster/namespace. No git clone.
#
#   curl -fsSL <raw>/client/install.sh | bash                              # default vLLM deploy + qa
#   curl -fsSL <raw>/client/install.sh | QWEN_NAMESPACE=trial bash -s -- --websearch
#   curl -fsSL <raw>/client/install.sh | bash -s -- --engine sglang
#   curl -fsSL <raw>/client/install.sh | bash -s -- --no-deploy            # install the launcher only
# where <raw> is https://raw.githubusercontent.com/littlemex/distributed-ai/abc1afaabf43b71c21e2b73acf333dc5d12a4ab5/2026-08-19-qwen3-8-27b-vllm-eks
#
# Env goes on `bash`, not `curl` (a var before `curl` is lost). All deploy flags (--engine, --only,
# --websearch, --yes, --skip-smoke, --purge-pool) are forwarded to deploy.sh. Installer flags:
# --ref <sha|branch>, --no-deploy. Env: QWEN_NAMESPACE (default qwen), QWEN_KUBE_CONTEXT (default
# current context); region and cluster are auto-derived from the context's EKS ARN. Repo coordinates:
# QWEN_REPO / QWEN_REF; a private repo needs GITHUB_TOKEN. During development REF defaults to the
# feature branch so fixes land without re-pinning the URL; pass QWEN_REF / --ref (a tag or SHA) to
# pin the exact code, and this default will become a release tag once merged.
set -euo pipefail

REPO="${QWEN_REPO:-littlemex/distributed-ai}"
REF="${QWEN_REF:-feat/serving-vllm-qwen}"
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
# download then extract as separate steps so an HTTP error is distinct from an extract error
curl -fSL "${AUTH[@]+"${AUTH[@]}"}" -o "$TMP/src.tgz" "https://codeload.github.com/$REPO/tar.gz/$REF" \
  || die "download failed ($REPO@$REF) — a private repo needs GITHUB_TOKEN; check QWEN_REF"
tar -xzf "$TMP/src.tgz" -C "$TMP" || die "extract failed"
SRC=""; for d in "$TMP"/*/"$SUBDIR"; do [ -d "$d" ] && SRC="$d"; done
[ -n "$SRC" ] || die "subdir $SUBDIR not found in $REPO@$REF"

if [ "$DO_DEPLOY" = 1 ]; then
  # is --yes among the forwarded flags?
  has_yes=0; for a in ${PASS[@]+"${PASS[@]}"}; do [ "$a" = --yes ] && has_yes=1; done
  if [ "${#PASS[@]}" -gt 0 ]; then say "deploying (flags: ${PASS[*]})"; else say "deploying"; fi
  if [ -e /dev/tty ]; then
    # a terminal is present: let deploy.sh's confirm prompt read from it
    ( cd "$SRC" && ./scripts/deploy.sh "${PASS[@]+"${PASS[@]}"}" ) </dev/tty
  elif [ "$has_yes" = 1 ]; then
    ( cd "$SRC" && ./scripts/deploy.sh "${PASS[@]+"${PASS[@]}"}" )
  else
    die "no TTY to confirm the target cluster; re-run with --yes to proceed non-interactively"
  fi
fi

say "installing launcher -> ~/.local/bin/qwen-agents (+ qa)"
mkdir -p "$HOME/.local/bin"
install -m 755 "$SRC/client/qwen-agents.sh" "$HOME/.local/bin/qwen-agents"
ln -sf "$HOME/.local/bin/qwen-agents" "$HOME/.local/bin/qa"
# record the deploy target so `qa` (a fresh shell) resolves the same cluster/namespace it deployed to
RESOLVED_CTX="${QWEN_KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}"
{ echo "KUBE_CONTEXT=$RESOLVED_CTX"; echo "NAMESPACE=${QWEN_NAMESPACE:-qwen}"; } > "$HOME/.local/bin/agents.env"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) : ;;
  *)
    # pick the rc the user's interactive login shell actually reads; macOS bash reads .bash_profile
    case "$(uname -s):$(basename "${SHELL:-sh}")" in
      *:zsh)      rc="$HOME/.zshrc";;
      Darwin:bash) rc="$HOME/.bash_profile";;
      *:bash)     rc="$HOME/.bashrc";;
      *)          rc="$HOME/.profile";;
    esac
    line='export PATH="$HOME/.local/bin:$PATH"'
    grep -qxF "$line" "$rc" 2>/dev/null || printf '\n%s\n' "$line" >> "$rc"
    export PATH="$HOME/.local/bin:$PATH"
    say "added ~/.local/bin to PATH in $rc — open a new terminal or run: exec \"\$SHELL\" -l"
    ;;
esac

say "done. launch an agent:  qa opencode    (also: qa qwen-code | hermes | openclaw)"
