#!/usr/bin/env bash
# One-shot installer. Fetches this reference, deploys the stack, installs the `qa` launcher onto
# PATH, and records the deploy target so `qa` reaches the same cluster/namespace. No git clone.
#
#   curl -fsSL <raw>/client/install.sh | bash                          # DeepSeek-V4-Flash + qa
#   curl -fsSL <raw>/client/install.sh | bash -s -- --profile smoke    # cheap/fast gpt-oss-20b
#   curl -fsSL <raw>/client/install.sh | FT_NAMESPACE=ft-trial bash -s -- --yes
#   curl -fsSL <raw>/client/install.sh | bash -s -- --no-deploy        # install the launcher only
# where <raw> is https://raw.githubusercontent.com/<owner>/<repo>/<full-sha>/2026-08-23-deepseek-v4-flash-freetoken-eks
#
# Pin <raw> to a COMMIT SHA, not a branch: the tag the deploy runs and the code that produced it
# should be the same thing months later.
#
# Env goes on `bash`, not `curl` (a variable before `curl` is lost by the pipe). Deploy flags
# (--profile, --only, --skip-pool, --purge-pool, --yes) are forwarded to deploy.sh. Installer flags:
# --ref <sha|branch>, --no-deploy. Env: FT_NAMESPACE (default freetoken), FT_KUBE_CONTEXT (default
# the current context); region and cluster are derived from the context's EKS ARN. Repo coordinates:
# FT_REPO / FT_REF / FT_DIR; a private repo needs GITHUB_TOKEN.
#
# PROFILES, because they differ by more than a factor of ten in both speed and price:
#   dsv4  (default) deepseek-ai/DeepSeek-V4-Flash-0731 on g6e.8xlarge (~$4.53/hr). 284B params from
#         one 45 GiB L40S, with 143 GiB of experts pinned in host RAM. Ready in ~13 min. Measured
#         ~15 tok/s decode, TTFT ~11 s -- generation reads fine, but every turn waits on prefill.
#   smoke openai/gpt-oss-20b on g6e.xlarge (far cheaper). Ready in ~6 min, measured ~96 tok/s with
#         TTFT ~0.9 s. The agent wiring is identical, so this is the better first run.
# Tear down either with `deploy.sh --down`; the GPU bills per hour while it is up.
set -euo pipefail

REPO="${FT_REPO:-littlemex/distributed-ai}"
REF="${FT_REF:-main}"
SUBDIR="${FT_DIR:-2026-08-23-deepseek-v4-flash-freetoken-eks}"
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
  || die "download failed ($REPO@$REF) — a private repo needs GITHUB_TOKEN; check FT_REF"
tar -xzf "$TMP/src.tgz" -C "$TMP" || die "extract failed"
SRC=""; for d in "$TMP"/*/"$SUBDIR"; do [ -d "$d" ] && SRC="$d"; done
[ -n "$SRC" ] || die "subdir $SUBDIR not found in $REPO@$REF"
chmod +x "$SRC"/scripts/*.sh "$SRC"/scripts/*.py "$SRC"/client/*.sh "$SRC"/storage/*.sh \
  "$SRC"/serving/image/*.sh 2>/dev/null || true

if [ "$DO_DEPLOY" = 1 ]; then
  # deploy.sh REQUIRES a profile, so a bare `curl | bash` would die on a missing flag. Default to
  # the model this reference exists for, and let --profile among the forwarded flags win.
  has_profile=0; has_yes=0
  for a in ${PASS[@]+"${PASS[@]}"}; do
    [ "$a" = --profile ] && has_profile=1
    [ "$a" = --yes ] && has_yes=1
  done
  [ "$has_profile" = 1 ] || PASS=(--profile dsv4 ${PASS[@]+"${PASS[@]}"})
  say "deploying (flags: ${PASS[*]})"
  if [ -e /dev/tty ]; then
    # a terminal is present: let deploy.sh's confirm prompt read from it, since this script's own
    # stdin is the curl pipe
    ( cd "$SRC" && ./scripts/deploy.sh "${PASS[@]}" ) </dev/tty
  elif [ "$has_yes" = 1 ]; then
    ( cd "$SRC" && ./scripts/deploy.sh "${PASS[@]}" )
  else
    die "no TTY to confirm the target cluster; re-run with --yes to proceed non-interactively"
  fi
fi

say "installing launcher -> ~/.local/bin/ft-agents (+ qa)"
mkdir -p "$HOME/.local/bin"
install -m 755 "$SRC/client/ft-agents.sh" "$HOME/.local/bin/ft-agents"
ln -sf "$HOME/.local/bin/ft-agents" "$HOME/.local/bin/qa"
# record the deploy target so `qa` in a fresh shell resolves the cluster/namespace it deployed to
RESOLVED_CTX="${FT_KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}"
{ echo "KUBE_CONTEXT=$RESOLVED_CTX"; echo "NAMESPACE=${FT_NAMESPACE:-freetoken}"; } > "$HOME/.local/bin/agents.env"

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

say "done. launch an agent:  qa opencode    (also: qa hermes | qa openclaw)"
say "stop the GPU when finished:  qa down is NOT enough — run deploy.sh --down"
