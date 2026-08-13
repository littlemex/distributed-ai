#!/usr/bin/env bash
# Basic09 — remove the Neuron serving Deployment and Service.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart="${CHART:-$(cd "$here/../../.." && pwd)/charts/experiments}"
ns="${NAMESPACE:?set NAMESPACE}"
helm template exp "$chart" -f "$here/values.yaml" --set namespace="$ns" | kubectl delete --ignore-not-found -f -
