#!/usr/bin/env bash
# Basic07 — remove the GPU serving Deployment and Service.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart="${CHART:-$(cd "$here/../../.." && pwd)/charts/experiments}"
ns="${NAMESPACE:?set NAMESPACE}"
role="${NODE_ROLE:-placeholder}"
helm template exp "$chart" -f "$here/values.yaml" --set namespace="$ns" \
  --set gpuServingVllm.nodeRole="$role" | kubectl delete --ignore-not-found -f -
