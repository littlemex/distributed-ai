#!/usr/bin/env bash
# Basic07 — deploy a small vLLM OpenAI server on the GPU pool via charts/experiments.
# Env: NAMESPACE, NODE_ROLE (the accelerator_pools key / node-role label of the GPU pool). CHART,
# ROLLOUT_TIMEOUT optional.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart="${CHART:-$(cd "$here/../../.." && pwd)/charts/experiments}"
ns="${NAMESPACE:?set NAMESPACE}"
role="${NODE_ROLE:?set NODE_ROLE (the GPU pool key)}"
helm dependency build "$chart" >/dev/null 2>&1 || true
helm template exp "$chart" -f "$here/values.yaml" --set namespace="$ns" \
  --set gpuServingVllm.nodeRole="$role" | kubectl apply -f -
kubectl -n "$ns" rollout status deploy/gpu-vllm --timeout="${ROLLOUT_TIMEOUT:-15m}"
