#!/usr/bin/env bash
# Render and apply a single-model vLLM serving Deployment + Service onto the target
# GPU Karpenter pool. No Helm release is installed; we `helm template | kubectl apply`
# to match the infra/eks workflow (no CD controller in the base cluster).
#
# Usage:
#   NAMESPACE=qwen KCTX=<your-kube-context> ./up.sh qwen3.8-27b
#   NAMESPACE=qwen KCTX=<your-kube-context> ./up.sh qwen3.8-27b --down   # remove
set -euo pipefail

MODEL_KEY="${1:?usage: up.sh <model-key> (matches overlays/<model-key>.yaml)}"
shift || true
NAMESPACE="${NAMESPACE:-qwen}"
KCTX="${KCTX:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${HERE}/../charts/vllm-serving"
OVERLAY="${HERE}/../overlays/${MODEL_KEY}.yaml"

[ -f "$OVERLAY" ] || { echo "[NG] overlay not found: $OVERLAY"; exit 1; }
KCTL=(kubectl); [ -n "$KCTX" ] && KCTL=(kubectl --context "$KCTX")

# preflight: target GPU pool label must resolve to a schedulable pool (or be provisionable)
NODE_ROLE="$(helm template x "$CHART" -f "$OVERLAY" --show-only templates/deployment.yaml \
  | awk '/node-role:/{print $2; exit}')"
if ! "${KCTL[@]}" get nodepool "$NODE_ROLE" >/dev/null 2>&1 \
   && ! "${KCTL[@]}" get nodes -l "node-role=$NODE_ROLE" --no-headers 2>/dev/null | grep -q .; then
  echo "[NG] no NodePool or node with node-role=$NODE_ROLE"
  echo "     apply the pool first:  kubectl --context \$KCTX apply -f ../pool/nodepool-gpu-l40s.yaml"; exit 1
fi

if [ "${1:-}" = "--down" ]; then
  helm template x "$CHART" -f "$OVERLAY" -n "$NAMESPACE" | "${KCTL[@]}" delete -n "$NAMESPACE" -f - --ignore-not-found
  exit 0
fi

"${KCTL[@]}" create namespace "$NAMESPACE" --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
helm template x "$CHART" -f "$OVERLAY" -n "$NAMESPACE" | "${KCTL[@]}" apply -n "$NAMESPACE" -f -

DEPLOY="$(helm template x "$CHART" -f "$OVERLAY" --show-only templates/deployment.yaml | awk '/^  name:/{print $2; exit}')"
echo "[..] waiting for rollout of deploy/$DEPLOY (cold start pulls image + downloads weights + compiles)"
"${KCTL[@]}" -n "$NAMESPACE" rollout status "deploy/$DEPLOY" --timeout=45m
echo "[OK] $DEPLOY is ready in namespace $NAMESPACE"
