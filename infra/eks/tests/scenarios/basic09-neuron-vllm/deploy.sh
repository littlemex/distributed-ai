#!/usr/bin/env bash
# Basic09 — deploy Qwen3-VL on the vLLM Neuron plugin via charts/experiments.
# Env: NAMESPACE (required). CHART, ROLLOUT_TIMEOUT optional.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart="${CHART:-$(cd "$here/../../.." && pwd)/charts/experiments}"
ns="${NAMESPACE:?set NAMESPACE}"
# Vendor chart dependencies (image-builder-lib) so `helm template` can render; idempotent.
helm dependency build "$chart" >/dev/null 2>&1 || true
helm template exp "$chart" -f "$here/values.yaml" --set namespace="$ns" | kubectl apply -f -
kubectl -n "$ns" rollout status deploy/neuron-vllm --timeout="${ROLLOUT_TIMEOUT:-40m}"
