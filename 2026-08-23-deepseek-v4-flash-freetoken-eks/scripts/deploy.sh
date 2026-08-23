#!/usr/bin/env bash
# One-shot bring-up / teardown for the FreeToken serving reference on an EXISTING EKS cluster.
#
#   ./scripts/deploy.sh --profile smoke|dsv4 [--only pool|serving|agents] [--skip-pool] [--yes]
#   ./scripts/deploy.sh --down [--purge-pool] [--yes]
#
# Profiles, and why there are exactly two:
#   smoke -> openai/gpt-oss-20b on g6e.xlarge. Proves the image, chart, pool, and the S3 Files
#            mount on the cheapest node that can run FreeToken's offload path.
#   dsv4  -> deepseek-ai/DeepSeek-V4-Flash-0731 on g6e.8xlarge. The real target. Its 137 GiB of
#            expert banks must be page-locked in host RAM, which is what forces the 256 GiB node.
# Run smoke first: then a dsv4 failure can only be about capacity, never about plumbing.
#
# The instance type is never named here. Each profile's memory request steers Karpenter to a size
# within the one gpu-l40s-1x pool, so switching profiles needs no pool edit.
#
# Cluster creation, the S3 Files file system, and the container image are all out of scope:
#   storage/setup-s3files.sh   creates + wires the S3 Files model cache
#   storage/sync-checkpoint.sh populates a checkpoint into it
#   serving/image/             builds the FreeToken image
set -euo pipefail
export AWS_PAGER=""

HERE="$(cd "$(dirname "$0")/.." && pwd)"; cd "$HERE"

PROFILE=""; ONLY=""; ASSUME_YES=0; DOWN=0; PURGE_POOL=0; SKIP_POOL=0
while [ $# -gt 0 ]; do case "$1" in
  --profile) PROFILE="${2:?}"; shift 2;;
  --only) ONLY="${2:?}"; shift 2;;
  --yes) ASSUME_YES=1; shift;;
  --skip-pool|--skip-gpu) SKIP_POOL=1; shift;;
  --purge-pool) PURGE_POOL=1; shift;;
  --down) DOWN=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

case "$ONLY" in ""|pool|serving|agents) :;; *) echo "--only must be pool|serving|agents" >&2; exit 2;; esac
[ "$SKIP_POOL" = 1 ] && [ "$ONLY" = pool ] && { echo "--skip-pool and --only pool are contradictory" >&2; exit 2; }

NS="${FT_NAMESPACE:-freetoken}"
CTX="${FT_KUBE_CONTEXT:-$(kubectl config current-context)}"
K=(kubectl --context "$CTX" -n "$NS")
# AWS_PROFILE is honoured by the CLI directly from the environment, so there is no --profile
# plumbing here. An array-based one would also break under `set -u` on bash 3.2/4.3, where
# expanding an EMPTY array is an unbound-variable error (macOS still ships bash 3.2).

log(){ printf '\n\033[1;32m[deploy]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[deploy][warn]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[deploy][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
need kubectl; need aws; need helm; need python3; need envsubst

CTX_CLUSTER="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CTX')].context.cluster}" 2>/dev/null || true)"
case "$CTX_CLUSTER" in arn:aws:eks:*) :;; *) die "context '$CTX' is not an EKS ARN (got '$CTX_CLUSTER')";; esac
REGION="$(printf '%s' "$CTX_CLUSTER" | sed -n 's#^arn:aws:eks:\([^:]*\):.*#\1#p')"
CLUSTER="$(printf '%s' "$CTX_CLUSTER" | sed 's#.*/##')"

AGENTS=(opencode hermes openclaw)

# --- teardown -----------------------------------------------------------------------------------
if [ "$DOWN" = 1 ]; then
  [ "$ASSUME_YES" = 1 ] || { echo "  context: $CTX"; echo "  cluster: $CLUSTER"; echo "  namespace: $NS";
    read -r -p "Tear down FreeToken serving + agents? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || die "aborted by user"; }
  log "removing every freetoken-serving Deployment/Service in $NS"
  "${K[@]}" delete deploy,svc -l app.kubernetes.io/name=freetoken-serving --ignore-not-found >/dev/null 2>&1 || true
  "${K[@]}" delete -f serving/alias-freetoken.yaml --ignore-not-found >/dev/null 2>&1 || true
  for a in "${AGENTS[@]}"; do
    "${K[@]}" delete -f "agents/$a/deployment.yaml" --ignore-not-found >/dev/null 2>&1 || true
  done
  if [ "$PURGE_POOL" = 1 ]; then
    kubectl --context "$CTX" delete -f serving/pool/nodepool-gpu-l40s-1x.yaml --ignore-not-found >/dev/null 2>&1 || true
    log "removed the cluster-scoped NodePool gpu-l40s-1x (--purge-pool)"
  else
    log "kept the cluster-scoped NodePool gpu-l40s-1x (it is shared; --purge-pool removes it)"
  fi
  log "kept the S3 Files model cache and its PV/PVC (storage/setup-s3files.sh --down removes those)"
  exit 0
fi

[ -n "$PROFILE" ] || die "--profile smoke|dsv4 is required"
case "$PROFILE" in
  smoke) VALUES=serving/values/gpt-oss-20b.values.yaml;;
  dsv4)  VALUES=serving/values/deepseek-v4-flash.values.yaml;;
  *) die "--profile must be smoke|dsv4";;
esac
[ -f "$VALUES" ] || die "missing $VALUES"

# --- resolve the image --------------------------------------------------------------------------
# shellcheck source=/dev/null
. serving/image/image.env
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
IMAGE="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:${TAG}"

# --- read the profile's own values as the SINGLE source of truth ---------------------------------
# Everything downstream (the agent config's model id and context window, the preflight's floor) is
# derived from the same values file Helm renders, so the agents cannot advertise a model or a
# context length the engine is not actually serving.
read_values(){ python3 - "$VALUES" "$1" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")
d = yaml.safe_load(open(sys.argv[1])) or {}
v = d.get(sys.argv[2], "")
print("" if v is None else v)
PY
}
MODEL_ID="$(read_values model)"
SERVED_MODEL_NAME="$(read_values servedModelName)"; SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-$MODEL_ID}"
MAX_CONTEXT="$(read_values maxSeqLenOverride)"; MAX_CONTEXT="${MAX_CONTEXT:-32768}"
EXPERT_BANK_GIB="$(read_values expertBankGib)"
MEM_REQUEST="$(read_values memory)"

cat <<PLAN

  context   : $CTX
  cluster   : $CLUSTER ($REGION)
  namespace : $NS
  profile   : $PROFILE
  model     : $MODEL_ID  (served as $SERVED_MODEL_NAME, context $MAX_CONTEXT)
  host RAM  : ${EXPERT_BANK_GIB} GiB of pinned expert banks -> memory request ${MEM_REQUEST}
              (Karpenter picks the cheapest gpu-l40s-1x type that satisfies it)
  image     : $IMAGE

PLAN
[ "$ASSUME_YES" = 1 ] || { read -r -p "Proceed against this target? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || die "aborted by user"; }

kubectl --context "$CTX" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null

phase_pool(){ log "pool"; kubectl --context "$CTX" apply -f serving/pool/nodepool-gpu-l40s-1x.yaml; }

phase_serving(){
  log "serving ($PROFILE)"
  aws ecr describe-images --region "$REGION" --repository-name "$ECR_REPO" \
    --image-ids imageTag="$TAG" >/dev/null 2>&1 \
    || die "image ${ECR_REPO}:${TAG} not found in ECR. Build it first (serving/image/)."

  # The S3 Files profiles read the checkpoint from a PVC; a missing PVC would otherwise surface as
  # a pod stuck in ContainerCreating with no explanation.
  local claim; claim="$(python3 - "$VALUES" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
c = (d.get("checkpoint") or {})
print((c.get("s3files") or {}).get("claimName","") if c.get("source")=="s3files" else "")
PY
)"
  if [ -n "$claim" ]; then
    "${K[@]}" get pvc "$claim" >/dev/null 2>&1 \
      || die "PVC '$claim' not found in $NS. Run storage/setup-s3files.sh, then install storage/model-cache."
  fi

  local rendered; rendered="$(mktemp)"
  helm template x serving/charts/freetoken-serving -f "$VALUES" --set image="$IMAGE" -n "$NS" > "$rendered"
  local name; name="$(python3 - "$rendered" <<'PY'
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get("kind") == "Deployment":
        print(doc["metadata"]["name"]); break
PY
)"
  # Retire any OTHER freetoken-serving Deployment BEFORE applying this one. Order matters twice
  # over: the freetoken-serving alias selects on the chart label, so while two models' pods are
  # both Ready the alias load-balances across them and clients get answers from a model they did
  # not ask for; and on a same-size node the old pod's GPU and its unreclaimable pinned host pages
  # must be released before the new pod can start at all.
  for d in $("${K[@]}" get deploy -l app.kubernetes.io/name=freetoken-serving -o name 2>/dev/null); do
    case "$d" in
      *"/$name") : ;;
      *) log "removing previous model ${d#*/}"
         "${K[@]}" delete "$d" --ignore-not-found --wait=true >/dev/null 2>&1 || true;;
    esac
  done

  "${K[@]}" apply -f "$rendered" >/dev/null
  rm -f "$rendered"

  log "waiting for $name (first run: node launch + image pull + checkpoint read + pin-after-fill)"
  "${K[@]}" rollout status "deploy/$name" --timeout=70m || {
    "${K[@]}" get pods; kubectl --context "$CTX" get nodeclaims 2>/dev/null | tail -5
    warn "if the preflight initContainer failed, the node is too small for this model's pinned banks"
    die "serving not Ready"; }
  log "alias freetoken-serving -> $name"
  "${K[@]}" apply -f serving/alias-freetoken.yaml >/dev/null
}

phase_agents(){
  log "agents (backend: $SERVED_MODEL_NAME via the freetoken-serving alias)"
  local cfg; cfg="$(mktemp)"
  SERVED_MODEL_NAME="$SERVED_MODEL_NAME" MAX_CONTEXT="$MAX_CONTEXT" \
    envsubst '${SERVED_MODEL_NAME} ${MAX_CONTEXT}' < agents/opencode/opencode.pod.json.tmpl > "$cfg"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$cfg" \
    || die "rendered opencode config is not valid JSON"

  for a in "${AGENTS[@]}"; do
    "${K[@]}" apply -f "agents/$a/sa.yaml" >/dev/null
    case "$a" in
      opencode) "${K[@]}" create configmap opencode-files --from-file=opencode.json="$cfg" \
                  --from-file=bedrock_websearch.py=agents/tools/bedrock-websearch/bedrock_websearch.py \
                  --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null;;
      hermes)   "${K[@]}" create configmap hermes-tools \
                  --from-file=bedrock_websearch.py=agents/tools/bedrock-websearch/bedrock_websearch.py \
                  --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null;;
      openclaw) "${K[@]}" create configmap openclaw-tools \
                  --from-file=bedrock_websearch.py=agents/tools/bedrock-websearch/bedrock_websearch.py \
                  --from-file=AGENTS.md=agents/tools/bedrock-websearch/AGENTS.md \
                  --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null;;
    esac
    "${K[@]}" apply -f "agents/$a/deployment.yaml" >/dev/null
    "${K[@]}" set env deploy/"$a" FREETOKEN_MODEL="$SERVED_MODEL_NAME" >/dev/null 2>&1 || true
    "${K[@]}" rollout restart deploy/"$a" >/dev/null 2>&1 || true
  done
  rm -f "$cfg"
}

case "$ONLY" in
  pool)    phase_pool;;
  serving) phase_serving;;
  agents)  phase_agents;;
  "")      if [ "$SKIP_POOL" = 1 ]; then log "pool: skipped (--skip-pool)"; else phase_pool; fi
           phase_serving; phase_agents;;
esac

log "done (ns=$NS, profile=$PROFILE). Smoke it with:  python3 scripts/smoke.py --namespace $NS"
