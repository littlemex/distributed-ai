#!/usr/bin/env bash
# Basic07 — deploy a small vLLM OpenAI server on the GPU pool via charts/experiments.
# Env: NAMESPACE, NODE_ROLE (the accelerator_pools key / node-role label of the GPU pool). CHART,
# ROLLOUT_TIMEOUT optional.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart="${CHART:-$(cd "$here/../../.." && pwd)/charts/experiments}"
ns="${NAMESPACE:?set NAMESPACE}"
role="${NODE_ROLE:?set NODE_ROLE (the GPU pool key)}"
# `build` needs an existing Chart.lock; fall back to `update` (which regenerates it) when that's
# missing/stale. A real failure must still surface — see the longer comment in the Basic09 twin.
helm dependency build "$chart" 2>/dev/null || helm dependency update "$chart"
helm template exp "$chart" -f "$here/values.yaml" --set namespace="$ns" \
  --set gpuServingVllm.nodeRole="$role" | kubectl apply -f -
kubectl -n "$ns" rollout status deploy/gpu-vllm --timeout="${ROLLOUT_TIMEOUT:-15m}"
