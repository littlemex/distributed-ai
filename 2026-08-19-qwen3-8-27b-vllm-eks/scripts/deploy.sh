#!/usr/bin/env bash
# One-shot workload bring-up / teardown for the Qwen3.8-27B serving reference.
# Deploys the GPU pool, one serving engine, the agents, and the qwen-serving Service alias onto an
# EXISTING cluster (cluster creation is out of scope). Default engine is vLLM (verified); SGLang is
# an opt-in faster engine that needs a prebuilt image (see serving/sglang/README.md).
#
#   ./scripts/deploy.sh [--engine vllm|sglang] [--only pool|serving|agents] [--websearch] [--yes] [--skip-smoke]
#   ./scripts/deploy.sh --down [--yes]
#
# The Bedrock web_search tool is OPT-IN and off by default: without --websearch the agents deploy
# with no MCP/web_search wiring, no Bedrock role, and no Pod Identity association, and still do chat
# and tool-calling. With --websearch the tool is wired in; if QWEN_BEDROCK_ROLE_ARN is unset the
# script creates a least-privilege Bedrock role via scripts/setup-websearch-role.sh and uses it.
#
# Config (env): QWEN_KUBE_CONTEXT (default: current context), QWEN_NAMESPACE (default: qwen),
# QWEN_REGION (default: from context), QWEN_BEDROCK_REGION (default: QWEN_REGION),
# QWEN_WEBSEARCH (1 to enable, same as --websearch), QWEN_BEDROCK_ROLE_ARN (optional; only used with
# --websearch, auto-created when unset). The account is derived from the caller and is not overridable.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"; cd "$HERE"
ENGINE=vllm; ONLY=""; ASSUME_YES=0; SKIP_SMOKE=0; DOWN=0; WEBSEARCH="${QWEN_WEBSEARCH:-0}"
while [ $# -gt 0 ]; do case "$1" in
  --engine) ENGINE="${2:?}"; shift 2;;
  --only) ONLY="${2:?}"; shift 2;;
  --yes) ASSUME_YES=1; shift;;
  --skip-smoke) SKIP_SMOKE=1; shift;;
  --websearch) WEBSEARCH=1; shift;;
  --down) DOWN=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
case "$ENGINE" in vllm|sglang) :;; *) echo "--engine must be vllm|sglang" >&2; exit 2;; esac

NS="${QWEN_NAMESPACE:-qwen}"
CTX="${QWEN_KUBE_CONTEXT:-$(kubectl config current-context)}"
K=(kubectl --context "$CTX" -n "$NS")
# The context's cluster entry is an EKS ARN (arn:aws:eks:<region>:<acct>:cluster/<name>); derive both
# region and cluster name from it so neither needs an env var. AWS_REGION / aws config are fallbacks.
CTX_CLUSTER="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CTX')].context.cluster}" 2>/dev/null || true)"
QWEN_REGION="${QWEN_REGION:-$(printf '%s' "$CTX_CLUSTER" | sed -n 's#^arn:aws:eks:\([^:]*\):.*#\1#p')}"
QWEN_REGION="${QWEN_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}}"
QWEN_BEDROCK_REGION="${QWEN_BEDROCK_REGION:-$QWEN_REGION}"
CLUSTER_NAME="${CLUSTER_NAME:-$(printf '%s' "$CTX_CLUSTER" | sed 's#.*/##')}"
# shellcheck source=/dev/null
. serving/common/model.env

log(){ printf '\n\033[1;32m[deploy]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[deploy][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

confirm_target(){
  [ "$ASSUME_YES" = 1 ] && return 0
  local acct arn
  acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '?')"
  arn="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CTX')].context.cluster}" 2>/dev/null || echo '?')"
  echo "  context : $CTX"
  echo "  cluster : $arn"
  echo "  account : $acct"
  echo "  namespace: $NS   engine: $ENGINE"
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
hfOverrides: '{"rope_scaling":{"rope_type":"yarn","factor":${YARN_FACTOR}.0,"original_max_position_embeddings":${NATIVE_CONTEXT}}}'
MV
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

# NodePool is cluster-scoped; -n is irrelevant, so apply with the plain context.
phase_pool(){ log "pool"; kubectl --context "$CTX" apply -f serving/pool/nodepool-gpu-l40s.yaml; }

engine_deploy(){ [ "$1" = vllm ] && echo vllm-qwen-qwen3-8-27b || echo sglang-qwen; }

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
  render_engine | "${K[@]}" apply -f -
  "${K[@]}" delete "deploy/$other" --ignore-not-found >/dev/null 2>&1 || true
  log "waiting for $ENGINE Ready (first run 10-15 min: node + image + weights + warmup)"
  "${K[@]}" rollout status "deploy/$dname" --timeout=45m || {
    "${K[@]}" get pods 2>/dev/null; kubectl --context "$CTX" get nodeclaims 2>/dev/null | tail -5
    die "serving not Ready — check GPU quota and Karpenter NodeClaims"; }
  log "alias qwen-serving -> $ENGINE"
  "${K[@]}" apply -f "serving/alias-$ENGINE.yaml"
}

ensure_websearch_role(){
  # web_search is opt-in. When enabled without a caller-supplied role, create a least-privilege one.
  [ "$WEBSEARCH" = 1 ] || return 0
  [ -n "${QWEN_BEDROCK_ROLE_ARN:-}" ] && return 0
  log "web_search: QWEN_BEDROCK_ROLE_ARN unset — creating a least-privilege Bedrock role"
  QWEN_BEDROCK_ROLE_ARN="$(QWEN_REGION="$QWEN_REGION" scripts/setup-websearch-role.sh)" || die "Bedrock role creation failed"
  echo "  role: $QWEN_BEDROCK_ROLE_ARN"
}

# When web_search is off, strip the MCP block from an agent's JSON config so the tool is not wired.
# Echoes the path of the config to load (the original when on, a stripped temp file when off).
agent_config(){  # <src-json> <mcp-key>
  if [ "$WEBSEARCH" = 1 ]; then echo "$1"; return; fi
  local out; out="$(mktemp)"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop(sys.argv[2],None); json.dump(d,open(sys.argv[3],"w"),indent=2)' "$1" "$2" "$out"
  echo "$out"
}

phase_agents(){
  log "agents (web_search: $([ "$WEBSEARCH" = 1 ] && echo on || echo off))"
  ensure_websearch_role
  local AGENTS=(opencode qwen-code hermes openclaw) cfg
  for a in "${AGENTS[@]}"; do
    "${K[@]}" apply -f "agents/$a/sa.yaml" >/dev/null
    # config maps (config + the shared web_search tool script) — recreate idempotently
    case "$a" in
      opencode)  cfg="$(agent_config agents/opencode/opencode.pod.json mcp)"
                 "${K[@]}" create configmap opencode-files --from-file=opencode.json="$cfg" --from-file=bedrock_websearch.py=agents/tools/bedrock-websearch/bedrock_websearch.py --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null;;
      qwen-code) cfg="$(agent_config agents/qwen-code/settings.json mcpServers)"
                 "${K[@]}" create configmap qwen-code-files --from-file=settings.json="$cfg" --from-file=bedrock_websearch.py=agents/tools/bedrock-websearch/bedrock_websearch.py --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null;;
      hermes)    "${K[@]}" create configmap hermes-tools --from-file=bedrock_websearch.py=agents/tools/bedrock-websearch/bedrock_websearch.py --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null;;
      openclaw)  "${K[@]}" create configmap openclaw-tools --from-file=bedrock_websearch.py=agents/tools/bedrock-websearch/bedrock_websearch.py --from-file=AGENTS.md=agents/tools/bedrock-websearch/AGENTS.md --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null;;
    esac
    # Pod Identity association only when web_search is on and a role is available.
    if [ "$WEBSEARCH" = 1 ] && [ -n "${QWEN_BEDROCK_ROLE_ARN:-}" ]; then associate_pod_identity "$a"; fi
    "${K[@]}" apply -f "agents/$a/deployment.yaml" >/dev/null
    # hermes/openclaw read WEBSEARCH at startup to decide whether to wire the tool.
    "${K[@]}" set env deploy/"$a" WEBSEARCH="$WEBSEARCH" >/dev/null 2>&1 || true
    "${K[@]}" rollout restart deploy/"$a" >/dev/null 2>&1 || true   # pick up configmap changes
  done
}

associate_pod_identity(){
  local sa="$1" existing
  existing="$(aws eks list-pod-identity-associations --region "${QWEN_REGION:-}" --cluster-name "$CLUSTER_NAME" \
    --query "associations[?serviceAccount=='$sa' && namespace=='$NS'].associationArn" --output text 2>/dev/null || true)"
  if [ -z "$existing" ]; then
    aws eks create-pod-identity-association --region "${QWEN_REGION:-}" --cluster-name "$CLUSTER_NAME" \
      --namespace "$NS" --service-account "$sa" --role-arn "$QWEN_BEDROCK_ROLE_ARN" >/dev/null
  fi   # role-mismatch handling: left to the operator (list + fix), per design.
}

do_smoke(){ [ "$SKIP_SMOKE" = 1 ] && { log "smoke skipped"; return 0; }
  log "smoke"; python3 scripts/smoke.py --context "$CTX" --namespace "$NS" --engine "$ENGINE" \
    "$([ "$ENGINE" = sglang ] && echo --report || echo --gate)"; }

down(){
  confirm_target
  log "teardown (both engines + agents + alias + pool)"
  render_vllm   | "${K[@]}" delete -f - --ignore-not-found >/dev/null 2>&1 || true
  ENGINE=sglang; render_sglang 2>/dev/null | "${K[@]}" delete -f - --ignore-not-found >/dev/null 2>&1 || true
  "${K[@]}" delete -f serving/alias-vllm.yaml -f serving/alias-sglang.yaml --ignore-not-found >/dev/null 2>&1 || true
  for a in opencode qwen-code hermes openclaw; do
    "${K[@]}" delete -f "agents/$a/deployment.yaml" --ignore-not-found >/dev/null 2>&1 || true
    [ -n "${QWEN_BEDROCK_ROLE_ARN:-}" ] && { arn="$(aws eks list-pod-identity-associations --region "${QWEN_REGION:-}" --cluster-name "${CLUSTER_NAME:-}" --query "associations[?serviceAccount=='$a' && namespace=='$NS'].associationId" --output text 2>/dev/null || true)"; [ -n "$arn" ] && aws eks delete-pod-identity-association --region "${QWEN_REGION:-}" --cluster-name "$CLUSTER_NAME" --association-id "$arn" >/dev/null 2>&1 || true; }
  done
  kubectl --context "$CTX" delete -f serving/pool/nodepool-gpu-l40s.yaml --ignore-not-found >/dev/null 2>&1 || true
  log "teardown done"
}

# --- main ---------------------------------------------------------------------------------------
[ "$DOWN" = 1 ] && { down; exit 0; }
confirm_target
kubectl --context "$CTX" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
case "$ONLY" in
  pool)    phase_pool;;
  serving) phase_serving;;
  agents)  phase_agents;;
  "")      phase_pool; phase_serving; phase_agents; do_smoke;;
  *) die "--only must be pool|serving|agents";;
esac
log "done (engine=$ENGINE ns=$NS). Launch agents with:  qa opencode"
