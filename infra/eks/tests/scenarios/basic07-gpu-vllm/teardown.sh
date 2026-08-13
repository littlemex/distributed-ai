#!/usr/bin/env bash
# Basic07 — remove the GPU serving Deployment and Service. Not `-e`, and followed by a label-based
# fallback delete that does not depend on the chart at all — see the longer comment in the Basic09
# twin for why a swallowed re-render failure here would silently wedge the pool.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart="${CHART:-$(cd "$here/../../.." && pwd)/charts/experiments}"
ns="${NAMESPACE:?set NAMESPACE}"
role="${NODE_ROLE:-placeholder}"

helm dependency build "$chart" 2>/dev/null || helm dependency update "$chart" >/dev/null 2>&1
helm template exp "$chart" -f "$here/values.yaml" --set namespace="$ns" \
  --set gpuServingVllm.nodeRole="$role" 2>/dev/null \
  | kubectl delete --ignore-not-found -f - 2>/dev/null

kubectl delete deploy,svc -n "$ns" -l app=gpu-vllm --ignore-not-found --wait=true --timeout=60s
