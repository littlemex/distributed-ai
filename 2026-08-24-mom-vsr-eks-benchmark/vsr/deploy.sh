#!/usr/bin/env bash
# Deploy the Semantic Router benchmark front door.
#
# Everything environment-specific arrives through the environment, so this
# script and the manifests beside it carry no addresses, credentials or cluster
# names. Required:
#
#   KUBE_CONTEXT           kubectl context of the target cluster
#   STRATOCLAVE_HOST       host of the OpenAI-compatible gateway
#   STRATOCLAVE_API_KEY    gateway bearer token
#   QWEN_LOCAL_ENDPOINT    host:port of the in-cluster vLLM service
#   STRATOCLAVE_DEFAULTS   directory holding the gateway's models/pricing JSON
#
# Optional: NAMESPACE, VSR_IMAGE, ENVOY_IMAGE, VSR_STORAGE_CLASS,
# VSR_MODELS_VOLUME_SIZE, QUALITY_FROM, SELECTOR_WEIGHTS, GENERATED_DIR.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${KUBE_CONTEXT:?set KUBE_CONTEXT to the target cluster context}"
: "${STRATOCLAVE_HOST:?set STRATOCLAVE_HOST to the gateway host}"
: "${STRATOCLAVE_API_KEY:?set STRATOCLAVE_API_KEY to the gateway bearer token}"
: "${QWEN_LOCAL_ENDPOINT:?set QWEN_LOCAL_ENDPOINT to host:port of the in-cluster vLLM}"
: "${STRATOCLAVE_DEFAULTS:?set STRATOCLAVE_DEFAULTS to the gateway defaults directory}"

export NAMESPACE="${NAMESPACE:-vsr-bench}"
export VSR_IMAGE="${VSR_IMAGE:-ghcr.io/vllm-project/semantic-router/extproc:latest}"
export ENVOY_IMAGE="${ENVOY_IMAGE:-envoyproxy/envoy:v1.35-latest}"
export VSR_STORAGE_CLASS="${VSR_STORAGE_CLASS:-gp2}"
export VSR_MODELS_VOLUME_SIZE="${VSR_MODELS_VOLUME_SIZE:-20Gi}"
export STRATOCLAVE_PORT="${STRATOCLAVE_PORT:-443}"

generated="${GENERATED_DIR:-${HOME}/tmp/mom-vsr/generated}"

kube() { kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" "$@"; }

echo "[1/6] generating router and envoy configs"
build_args=()
if [[ -n "${QUALITY_FROM:-}" ]]; then
  build_args+=(--quality-from "${QUALITY_FROM}")
fi
# The selector's latency and load terms move with live traffic, so leaving them on
# during an accuracy measurement makes the routing decision a function of how hard
# the harness is pushing. An accuracy run sets them to zero; a serving deployment
# leaves the default alone.
if [[ -n "${SELECTOR_WEIGHTS:-}" ]]; then
  build_args+=(--weights "${SELECTOR_WEIGHTS}")
fi
python3 "${here}/build_config.py" \
  --stratoclave-defaults "${STRATOCLAVE_DEFAULTS}" \
  --out-dir "${generated}" \
  "${build_args[@]}"

echo "[2/6] namespace"
kubectl --context "${KUBE_CONTEXT}" create namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl --context "${KUBE_CONTEXT}" apply -f -

echo "[3/6] gateway credential"
# --dry-run | apply so a rotated key updates in place, and so the key never
# appears in a committed file or in the apply output.
kube create secret generic vsr-gateway-credentials \
  --from-literal=api-key="${STRATOCLAVE_API_KEY}" \
  --dry-run=client -o yaml | kube apply -f - > /dev/null
echo "      secret vsr-gateway-credentials applied"

echo "[4/6] configmaps"
kube create configmap vsr-router-config \
  --from-file=config.yaml="${generated}/router-config.yaml" \
  --dry-run=client -o yaml | kube apply -f -
kube create configmap vsr-envoy-config \
  --from-file=envoy.yaml="${generated}/envoy.yaml" \
  --dry-run=client -o yaml | kube apply -f -

echo "[5/6] workload"
# The checksum rolls the pod when either config changes; without it a ConfigMap
# update would leave the running router on the previous policy, which would
# silently attribute results to the wrong configuration.
CONFIG_CHECKSUM="$(cat "${generated}/router-config.yaml" "${generated}/envoy.yaml" |
  shasum -a 256 | cut -c1-16)"
export CONFIG_CHECKSUM
envsubst < "${here}/k8s/router.yaml" | kube apply -f -

echo "[6/6] waiting for rollout"
kube rollout status deployment/vsr --timeout=20m

echo
echo "[OK] router is up. Model download happens on first start; check progress with:"
echo "     kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE} logs deploy/vsr -c router --tail=20"
