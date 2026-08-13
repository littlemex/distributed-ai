#!/usr/bin/env bash
# Basic09 — deploy Qwen3-VL on the vLLM Neuron plugin via charts/experiments.
# Env: NAMESPACE (required). CHART, ROLLOUT_TIMEOUT optional.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart="${CHART:-$(cd "$here/../../.." && pwd)/charts/experiments}"
ns="${NAMESPACE:?set NAMESPACE}"
# Vendor chart dependencies (image-builder-lib) so `helm template` can render. `build` needs an
# existing Chart.lock; fall back to `update` (which regenerates it) when that's missing/stale. A
# real failure (e.g. a broken Chart.yaml) must still surface, not be swallowed — it would otherwise
# resurface downstream as a confusing `helm template` error with no vendoring context.
helm dependency build "$chart" 2>/dev/null || helm dependency update "$chart"
helm template exp "$chart" -f "$here/values.yaml" --set namespace="$ns" | kubectl apply -f -
kubectl -n "$ns" rollout status deploy/neuron-vllm --timeout="${ROLLOUT_TIMEOUT:-40m}"
