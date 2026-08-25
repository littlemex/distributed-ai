#!/usr/bin/env bash
# One-shot workload bring-up / teardown for the Qwen3.8-27B serving reference.
# Deploys the GPU pool, one serving engine, the agents, and the qwen-serving Service alias onto an
# EXISTING cluster (cluster creation is out of scope). Default engine is vLLM (verified); SGLang is
# an opt-in faster engine that needs a prebuilt image (see serving/sglang/README.md).
#
#   ./scripts/deploy.sh [--engine vllm|sglang] [--context 131k|262k|1m] [--only pool|serving|agents]
#                       [--skip-pool] [--websearch] [--yes] [--skip-smoke]
#
# --context picks the window and, with it, how many sequences fit: 131k/16, 262k/9 (default,
# the model's native window and so no rope scaling), 1m/2 (YaRN). --tune picks what to
# optimise: latency (MTP speculative decoding, the default) or throughput (MTP off, a large
# scheduler budget, more sequences). See serving/common/context-profiles.env.
#   ./scripts/deploy.sh --down [--purge-pool] [--yes]
#
# --skip-pool (alias --skip-gpu): run the full flow WITHOUT the GPU NodePool phase, for a cluster that
# already has a compatible pool. Combine with --websearch for a single serving+agents+web_search shot.
#
# The Bedrock web_search tool is OPT-IN and off by default: without --websearch the agents deploy
# with no MCP/web_search wiring, no Bedrock role, and no Pod Identity association, and still do chat
# and tool-calling. With --websearch the tool is wired in; if QWEN_BEDROCK_ROLE_ARN is unset the
# script creates a Bedrock role (AmazonBedrockFullAccess) via scripts/setup-websearch-role.sh.
# web_search lives in the agents phase, so it is rejected with --only pool|serving.
#
# Config (env): QWEN_KUBE_CONTEXT (default: current context), QWEN_NAMESPACE (default: qwen),
# QWEN_REGION (default: derived from the context's EKS ARN), QWEN_BEDROCK_REGION (default: us-east-1,
# a web_search-supported region), QWEN_WEBSEARCH (1 to enable, same as --websearch),
# QWEN_BEDROCK_ROLE_ARN (optional; only with --websearch, auto-created when unset), CLUSTER_NAME
# (default: derived from the context). The account is derived from the caller and is not overridable.
set -euo pipefail
export AWS_PAGER=""   # keep aws CLI from paginating / injecting output that would pollute captures

HERE="$(cd "$(dirname "$0")/.." && pwd)"; cd "$HERE"
ENGINE=vllm; ONLY=""; ASSUME_YES=0; SKIP_SMOKE=0; DOWN=0; PURGE_POOL=0; SKIP_POOL=0; WEBSEARCH="${QWEN_WEBSEARCH:-0}"
while [ $# -gt 0 ]; do case "$1" in
  --engine) ENGINE="${2:?}"; shift 2;;
  --context) QWEN_CONTEXT="${2:?}"; shift 2;;
  --tune) QWEN_TUNE="${2:?}"; shift 2;;
  --only) ONLY="${2:?}"; shift 2;;
  --yes) ASSUME_YES=1; shift;;
  --skip-smoke) SKIP_SMOKE=1; shift;;
  --skip-pool|--skip-gpu) SKIP_POOL=1; shift;;
  --websearch) WEBSEARCH=1; shift;;
  --purge-pool) PURGE_POOL=1; shift;;
  --down) DOWN=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
case "$ENGINE" in vllm|sglang) :;; *) echo "--engine must be vllm|sglang" >&2; exit 2;; esac
case "$ONLY" in ""|pool|serving|agents) :;; *) echo "--only must be pool|serving|agents" >&2; exit 2;; esac
[ "$SKIP_POOL" = 1 ] && [ "$ONLY" = pool ] && { echo "--skip-pool and --only pool are contradictory" >&2; exit 2; }
# web_search wiring lives in the agents phase; a --only pool|serving run would silently drop it.
if [ "$WEBSEARCH" = 1 ] && [ -n "$ONLY" ] && [ "$ONLY" != agents ]; then
  echo "--websearch needs the agents phase: use --websearch with no --only, or --websearch --only agents" >&2; exit 2
fi

# capture caller-supplied values before defaulting, so the ARN guard can tell them apart
_ENV_REGION="${QWEN_REGION:-}"; _ENV_CLUSTER="${CLUSTER_NAME:-}"
NS="${QWEN_NAMESPACE:-qwen}"
CTX="${QWEN_KUBE_CONTEXT:-$(kubectl config current-context)}"
K=(kubectl --context "$CTX" -n "$NS")
# The context's cluster entry is an EKS ARN (arn:aws:eks:<region>:<acct>:cluster/<name>); derive both
# region and cluster name from it so neither needs an env var. AWS_REGION / aws config are fallbacks.
CTX_CLUSTER="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CTX')].context.cluster}" 2>/dev/null || true)"
QWEN_REGION="${QWEN_REGION:-$(printf '%s' "$CTX_CLUSTER" | sed -n 's#^arn:aws:eks:\([^:]*\):.*#\1#p')}"
QWEN_REGION="${QWEN_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}}"
QWEN_BEDROCK_REGION="${QWEN_BEDROCK_REGION:-us-east-1}"   # Bedrock web_search: us-east-1|us-east-2|us-west-2
CLUSTER_NAME="${CLUSTER_NAME:-$(printf '%s' "$CTX_CLUSTER" | sed 's#.*/##')}"
# shellcheck source=/dev/null
. serving/common/model.env
. serving/common/context-profiles.env

log(){ printf '\n\033[1;32m[deploy]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[deploy][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# retry a command on failure with linear backoff, to ride out transient EKS API / network timeouts.
retry(){
  local max=5 n=1
  until "$@"; do
    n=$((n+1)); [ "$n" -gt "$max" ] && { printf '\033[1;31m[deploy][retry]\033[0m gave up after %d attempts: %s\n' "$max" "$*" >&2; return 1; }
    printf '\033[1;33m[deploy][retry]\033[0m attempt %d/%d in %ds: %s\n' "$n" "$max" $((n*3)) "$*" >&2
    sleep $((n*3))
  done
}
# apply YAML from stdin with retry (buffer to a temp file so each attempt re-reads the same input).
kapply_stdin(){ local t r; t="$(mktemp)"; cat > "$t"; retry "${K[@]}" apply -f "$t"; r=$?; rm -f "$t"; return $r; }

# preflight: fail early on a missing tool rather than mid-deploy. helm renders an engine (not needed
# for --only agents); envsubst renders the SGLang manifest; teardown renders both to delete them.
need kubectl; need aws; need python3
if [ "$DOWN" = 1 ] || [ "$ONLY" != agents ]; then need helm; fi
if [ "$DOWN" = 1 ] || [ "$ENGINE" = sglang ]; then need envsubst; fi

# web_search needs a real EKS context to place Pod Identity associations; a non-EKS/renamed context
# would derive a bogus cluster name and fail silently. Require an ARN, or explicit env overrides.
if [ "$WEBSEARCH" = 1 ]; then
  case "$CTX_CLUSTER" in
    arn:aws:eks:*) : ;;
    *) { [ -n "$_ENV_REGION" ] && [ -n "$_ENV_CLUSTER" ]; } \
         || die "web_search needs an EKS context (ARN-shaped), or explicit CLUSTER_NAME + QWEN_REGION; context '$CTX' resolved to '$CTX_CLUSTER'";;
  esac
fi

confirm_target(){
  [ "$ASSUME_YES" = 1 ] && return 0
  local acct
  acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '?')"
  echo "  context : $CTX"
  echo "  cluster : ${CTX_CLUSTER:-?}"
  echo "  account : $acct"
  echo "  namespace: $NS   engine: $ENGINE   web_search: $([ "$WEBSEARCH" = 1 ] && echo on || echo off)"
  echo "  context : ${QWEN_CONTEXT:-262k} (window $MAX_CONTEXT, up to $MAX_NUM_SEQS concurrent)"
  echo "  tune    : ${QWEN_TUNE:-latency} (step budget ${MAX_BATCHED_TOKENS:-auto}, mtp $([ -n "$SPEC_CONFIG" ] && echo on || echo off))"
  read -r -p "Proceed against this target? [y/N] " a
  [ "$a" = y ] || [ "$a" = Y ] || die "aborted by user"
}

# --- rendered manifests per engine (model.env injected; no drift) -------------------------------
render_vllm(){
  local mv; mv="$(mktemp)"
  cat > "$mv" <<MV
model: $MODEL_ID
servedModelName: $SERVED_MODEL_NAME
maxModelLen: $MAX_CONTEXT
maxNumSeqs: $MAX_NUM_SEQS
maxNumBatchedTokens: "$MAX_BATCHED_TOKENS"
speculativeConfig: '$SPEC_CONFIG'
MV
  # YaRN only when the window asked for is longer than the model's own. Below native it
  # buys nothing and is not free: rope scaling trades short-context accuracy for reach, so
  # applying it at 131072 on a model whose native window is 262144 would pay that price
  # for length nobody requested.
  if [ "$MAX_CONTEXT" -gt "$NATIVE_CONTEXT" ]; then
    cat >> "$mv" <<MV
hfOverrides: '{"rope_scaling":{"rope_type":"yarn","factor":${YARN_FACTOR}.0,"original_max_position_embeddings":${NATIVE_CONTEXT}}}'
MV
  fi
  helm template x serving/charts/vllm-serving \
    -f serving/values/qwen3.8-27b.values.yaml -f "$mv" -n "$NS"
  rm -f "$mv"
}
render_sglang(){
  [ -f serving/sglang/manifests/qwen3.8-27b.sglang.yaml ] || die "sglang manifest missing"
  # shellcheck source=/dev/null
  . serving/sglang/image/image.env
  local acct sgimg; acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
  sgimg="${acct}.dkr.ecr.${QWEN_REGION}.amazonaws.com/${ECR_REPO}:${TAG}"
  # shellcheck disable=SC2016
  MODEL_ID="$MODEL_ID" SERVED_MODEL_NAME="$SERVED_MODEL_NAME" MAX_CONTEXT="$MAX_CONTEXT" \
  YARN_FACTOR="$YARN_FACTOR" NATIVE_CONTEXT="$NATIVE_CONTEXT" SGLANG_IMAGE="$sgimg" \
    envsubst '${MODEL_ID} ${SERVED_MODEL_NAME} ${MAX_CONTEXT} ${YARN_FACTOR} ${NATIVE_CONTEXT} ${SGLANG_IMAGE}' \
    < serving/sglang/manifests/qwen3.8-27b.sglang.yaml
}
render_engine(){ if [ "$ENGINE" = vllm ]; then render_vllm; else render_sglang; fi; }
other_engine(){ [ "$ENGINE" = vllm ] && echo sglang || echo vllm; }
engine_deploy(){ [ "$1" = vllm ] && echo vllm-qwen-qwen3-8-27b || echo sglang-qwen; }

# NodePool is cluster-scoped; -n is irrelevant, so apply with the plain context.
phase_pool(){ log "pool"; retry kubectl --context "$CTX" apply -f serving/pool/nodepool-gpu-l40s.yaml; }

phase_serving(){
  log "serving ($ENGINE)"
  if [ "$ENGINE" = sglang ]; then
    # shellcheck source=/dev/null
    [ -f serving/sglang/image/image.env ] && . serving/sglang/image/image.env
    if [ -n "${ECR_REPO:-}" ] && ! aws ecr describe-images --region "$QWEN_REGION" \
         --repository-name "$ECR_REPO" --image-ids imageTag="${TAG:-}" >/dev/null 2>&1; then
      die "SGLang image ${ECR_REPO}:${TAG:-} not found. Run serving/sglang/image/build.sh first (see serving/sglang/README.md)."
    fi
  fi
  local dname other; dname="$(engine_deploy "$ENGINE")"; other="$(engine_deploy "$(other_engine)")"
  # bring the new engine up, then free the GPU by removing the other engine (one engine per node).
  render_engine | kapply_stdin
  "${K[@]}" delete "deploy/$other" --ignore-not-found >/dev/null 2>&1 || true
  log "waiting for $ENGINE Ready (first run 10-15 min: node + image + weights + warmup)"
  "${K[@]}" rollout status "deploy/$dname" --timeout=45m || {
    "${K[@]}" get pods 2>/dev/null; kubectl --context "$CTX" get nodeclaims 2>/dev/null | tail -5
    die "serving not Ready — check GPU quota and Karpenter NodeClaims"; }
  log "alias qwen-serving -> $ENGINE"
  retry "${K[@]}" apply -f "serving/alias-$ENGINE.yaml"
}

ensure_websearch_role(){
  # web_search is opt-in. When enabled without a caller-supplied role, create a least-privilege one.
  [ "$WEBSEARCH" = 1 ] || return 0
  [ -n "${QWEN_BEDROCK_ROLE_ARN:-}" ] && return 0
  log "web_search: QWEN_BEDROCK_ROLE_ARN unset — creating a Bedrock role (AmazonBedrockFullAccess)"
  QWEN_BEDROCK_ROLE_ARN="$(QWEN_REGION="$QWEN_REGION" scripts/setup-websearch-role.sh)" || die "Bedrock role creation failed"
  case "$QWEN_BEDROCK_ROLE_ARN" in
    arn:aws:iam::*) echo "  role: $QWEN_BEDROCK_ROLE_ARN";;
    *) die "setup-websearch-role.sh did not return a role ARN (got: '$QWEN_BEDROCK_ROLE_ARN')";;
  esac
}

# Render an agent's JSON config. web_search off: strip the MCP block so the tool is not wired.
# web_search on: point the MCP tool's region env at QWEN_BEDROCK_REGION. Echoes the path to load.
agent_config(){  # <src-json> <mcp-key>
  local out; out="$(mktemp)"
  WS="$WEBSEARCH" WSREGION="$QWEN_BEDROCK_REGION" python3 - "$1" "$2" "$out" <<'PY'
import json, os, sys
src, key, out = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(src))
if os.environ.get("WS") == "1":
    reg = os.environ.get("WSREGION") or "us-east-1"
    for _, server in (d.get(key) or {}).items():
        for ek in ("environment", "env"):
            env = server.get(ek)
            if isinstance(env, dict):
                for rk in ("AWS_REGION", "BEDROCK_WS_REGION"):
                    if rk in env:
                        env[rk] = reg
else:
    d.pop(key, None)
json.dump(d, open(out, "w"), indent=2)
PY
  [ -s "$out" ] || return 1
  echo "$out"
}

phase_agents(){
  log "agents (web_search: $([ "$WEBSEARCH" = 1 ] && echo on || echo off))"
  ensure_websearch_role
  local AGENTS=(opencode qwen-code hermes openclaw) cfg
  for a in "${AGENTS[@]}"; do
    retry "${K[@]}" apply -f "agents/$a/sa.yaml" >/dev/null
    # config maps (config + the shared web_search tool script) — recreate idempotently
    case "$a" in
      opencode)  cfg="$(agent_config agents/opencode/opencode.pod.json mcp)" || die "opencode config render failed"
                 "${K[@]}" create configmap opencode-files --from-file=opencode.json="$cfg" --from-file=bedrock_websearch.py=agents/tools/bedrock-websearch/bedrock_websearch.py --dry-run=client -o yaml | kapply_stdin >/dev/null;;
      qwen-code) cfg="$(agent_config agents/qwen-code/settings.json mcpServers)" || die "qwen-code config render failed"
                 "${K[@]}" create configmap qwen-code-files --from-file=settings.json="$cfg" --from-file=bedrock_websearch.py=agents/tools/bedrock-websearch/bedrock_websearch.py --dry-run=client -o yaml | kapply_stdin >/dev/null;;
      hermes)    "${K[@]}" create configmap hermes-tools --from-file=bedrock_websearch.py=agents/tools/bedrock-websearch/bedrock_websearch.py --dry-run=client -o yaml | kapply_stdin >/dev/null;;
      openclaw)  "${K[@]}" create configmap openclaw-tools --from-file=bedrock_websearch.py=agents/tools/bedrock-websearch/bedrock_websearch.py --from-file=AGENTS.md=agents/tools/bedrock-websearch/AGENTS.md --dry-run=client -o yaml | kapply_stdin >/dev/null;;
    esac
    # Pod Identity association is declarative: on => ensure it, off => remove any leftover so "off"
    # really means no Bedrock credentials on the ServiceAccount.
    if [ "$WEBSEARCH" = 1 ] && [ -n "${QWEN_BEDROCK_ROLE_ARN:-}" ]; then associate_pod_identity "$a"; else disassociate_pod_identity "$a"; fi
    retry "${K[@]}" apply -f "agents/$a/deployment.yaml" >/dev/null
    # hermes/openclaw read WEBSEARCH + BEDROCK_WS_REGION from container env at startup (opencode and
    # qwen-code are controlled by their config instead, so setting it on them would be a no-op).
    case "$a" in hermes|openclaw)
      if [ "$WEBSEARCH" = 1 ]; then
        retry "${K[@]}" set env deploy/"$a" WEBSEARCH=1 BEDROCK_WS_REGION="$QWEN_BEDROCK_REGION" AWS_REGION="$QWEN_BEDROCK_REGION" >/dev/null 2>&1 || true
      else
        retry "${K[@]}" set env deploy/"$a" WEBSEARCH=0 >/dev/null 2>&1 || true
      fi;;
    esac
    retry "${K[@]}" rollout restart deploy/"$a" >/dev/null 2>&1 || true   # pick up configmap changes
  done
}

associate_pod_identity(){
  local sa="$1" existing role
  existing="$(aws eks list-pod-identity-associations --region "$QWEN_REGION" --cluster-name "$CLUSTER_NAME" \
    --query "associations[?serviceAccount=='$sa' && namespace=='$NS'].associationId" --output text 2>/dev/null || true)"
  if [ -z "$existing" ] || [ "$existing" = None ]; then
    retry aws eks create-pod-identity-association --region "$QWEN_REGION" --cluster-name "$CLUSTER_NAME" \
      --namespace "$NS" --service-account "$sa" --role-arn "$QWEN_BEDROCK_ROLE_ARN" >/dev/null \
      || die "failed to create Pod Identity association for $sa (region=$QWEN_REGION cluster=$CLUSTER_NAME)"
  else
    role="$(aws eks describe-pod-identity-association --region "$QWEN_REGION" --cluster-name "$CLUSTER_NAME" \
      --association-id "$existing" --query 'association.roleArn' --output text 2>/dev/null || true)"
    [ "$role" = "$QWEN_BEDROCK_ROLE_ARN" ] || log "[warn] $sa Pod Identity already points at $role (not $QWEN_BEDROCK_ROLE_ARN); leaving it — delete it to switch roles"
  fi
}

disassociate_pod_identity(){
  local sa="$1" id
  id="$(aws eks list-pod-identity-associations --region "$QWEN_REGION" --cluster-name "$CLUSTER_NAME" \
    --query "associations[?serviceAccount=='$sa' && namespace=='$NS'].associationId" --output text 2>/dev/null || true)"
  { [ -n "$id" ] && [ "$id" != None ]; } || return 0
  aws eks delete-pod-identity-association --region "$QWEN_REGION" --cluster-name "$CLUSTER_NAME" \
    --association-id "$id" >/dev/null 2>&1 || true
}

do_smoke(){ [ "$SKIP_SMOKE" = 1 ] && { log "smoke skipped"; return 0; }
  log "smoke"; python3 scripts/smoke.py --context "$CTX" --namespace "$NS" --engine "$ENGINE" \
    "$([ "$ENGINE" = sglang ] && echo --report || echo --gate)"; }

down(){
  confirm_target
  log "teardown (both engine Deployments + agents + alias)"
  for d in "$(engine_deploy vllm)" "$(engine_deploy sglang)"; do
    "${K[@]}" delete "deploy/$d" "svc/$d" --ignore-not-found >/dev/null 2>&1 || true
  done
  "${K[@]}" delete -f serving/alias-vllm.yaml -f serving/alias-sglang.yaml --ignore-not-found >/dev/null 2>&1 || true
  for a in opencode qwen-code hermes openclaw; do
    "${K[@]}" delete -f "agents/$a/deployment.yaml" --ignore-not-found >/dev/null 2>&1 || true
    disassociate_pod_identity "$a"   # unconditional: an auto-created role's ARN is not in env at teardown
  done
  if [ "$PURGE_POOL" = 1 ]; then
    kubectl --context "$CTX" delete -f serving/pool/nodepool-gpu-l40s.yaml --ignore-not-found >/dev/null 2>&1 || true
    log "removed the cluster-scoped GPU NodePool (--purge-pool)"
  else
    log "kept the cluster-scoped GPU NodePool gpu-l40s (pass --purge-pool to remove it — it is shared)"
  fi
  log "teardown done. An auto-created Bedrock role is left in place; remove it with 'aws iam delete-role-policy'/'delete-role' if unused."
}

# --- main ---------------------------------------------------------------------------------------
[ "$DOWN" = 1 ] && { down; exit 0; }
confirm_target
kubectl --context "$CTX" create namespace "$NS" --dry-run=client -o yaml | kapply_stdin >/dev/null
case "$ONLY" in
  pool)    phase_pool;      log "smoke: not applicable with --only pool";;
  serving) phase_serving;   do_smoke;;
  agents)  phase_agents;    log "smoke: not run with --only agents (it does not (re)deploy serving)";;
  "")      if [ "$SKIP_POOL" = 1 ]; then log "pool: skipped (--skip-pool)"; else phase_pool; fi
           phase_serving; phase_agents; do_smoke;;
esac
log "done (ns=$NS). Launch agents with:  qa opencode"
