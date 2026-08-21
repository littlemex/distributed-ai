#!/usr/bin/env bash
# Port-forward a served model's Service to localhost for a quick check.
# Demo use only; not a shared-access mechanism.
#   NAMESPACE=qwen KCTX=<your-kube-context> ./port-forward.sh qwen3.8-27b 8000
set -euo pipefail
MODEL_KEY="${1:?usage: port-forward.sh <model-key> [localport]}"
LOCALPORT="${2:-8000}"
NAMESPACE="${NAMESPACE:-qwen}"
KCTX="${KCTX:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${HERE}/../charts/vllm-serving"
OVERLAY="${HERE}/../overlays/${MODEL_KEY}.yaml"
KCTL=(kubectl); [ -n "$KCTX" ] && KCTL=(kubectl --context "$KCTX")

SVC="$(helm template x "$CHART" -f "$OVERLAY" --show-only templates/service.yaml | awk '/^  name:/{print $2; exit}')"
echo "[..] port-forward svc/$SVC -> localhost:$LOCALPORT (Ctrl-C to stop)"
exec "${KCTL[@]}" -n "$NAMESPACE" port-forward "svc/$SVC" "${LOCALPORT}:8000"
