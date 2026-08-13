#!/usr/bin/env bash
# Basic09 — remove the Neuron serving Deployment and Service. Called from run-tests.sh's EXIT/TERM
# trap on both the success and the failure path, so it must not depend on `helm template`
# succeeding: a stale vendored dependency or a values.yaml edit made between deploy and teardown
# could break re-rendering, and a swallowed failure here would silently leave the Deployment
# holding the node's single Trainium device — wedging every subsequent `--suite neuron` run.
# Render+delete is attempted first (it also clears the Service); the label-based delete below is
# the guaranteed fallback and does not depend on the chart at all.
set -uo pipefail  # intentionally not -e: fall through to the fallback delete even if templating fails
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart="${CHART:-$(cd "$here/../../.." && pwd)/charts/experiments}"
ns="${NAMESPACE:?set NAMESPACE}"

helm dependency build "$chart" 2>/dev/null || helm dependency update "$chart" >/dev/null 2>&1
helm template exp "$chart" -f "$here/values.yaml" --set namespace="$ns" 2>/dev/null \
  | kubectl delete --ignore-not-found -f - 2>/dev/null

kubectl delete deploy,svc -n "$ns" -l app=neuron-vllm --ignore-not-found --wait=true --timeout=60s
