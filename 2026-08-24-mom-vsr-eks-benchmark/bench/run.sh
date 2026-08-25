#!/usr/bin/env bash
# Run one measurement as a Job in the cluster that hosts the router.
#
#   ./run.sh <run-id> <collect.py arguments...>
#
# Example:
#   ./run.sh calib-01 matrix --fold calibration --samples 200 \
#     --categories math law health engineering economics philosophy "computer science"
#
# Everything environment-specific arrives through the environment, so this script
# and the manifest beside it carry no cluster names or addresses. Required:
#
#   KUBE_CONTEXT           kubectl context of the cluster running the router
#   STRATOCLAVE_DEFAULTS   directory holding the gateway's models/pricing JSON
#
# Optional: NAMESPACE, BENCH_IMAGE, BENCH_STORAGE_CLASS, BENCH_VOLUME_SIZE,
# UPSTREAM_REPO, UPSTREAM_COMMIT.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${KUBE_CONTEXT:?set KUBE_CONTEXT to the cluster running the router}"
: "${STRATOCLAVE_DEFAULTS:?set STRATOCLAVE_DEFAULTS to the gateway defaults directory}"

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <run-id> <collect.py arguments...>" >&2
  exit 2
fi
export RUN_ID="$1"
shift

export NAMESPACE="${NAMESPACE:-vsr-bench}"
export BENCH_IMAGE="${BENCH_IMAGE:-python:3.11-slim}"
# Results have to outlive the Job and be readable while it runs, so the volume is
# shared rather than block: a ReadWriteOnce claim would be locked to the Job's own
# node and unreadable from anywhere else until it finished.
export BENCH_STORAGE_CLASS="${BENCH_STORAGE_CLASS:-efs-shared}"
export BENCH_VOLUME_SIZE="${BENCH_VOLUME_SIZE:-20Gi}"
export UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/vllm-project/semantic-router.git}"
# Pinned: this commit's datasets and scorer are part of the result. Spelled in
# full because a fetch of a single commit has to name it exactly — an abbreviated
# sha is not a remote ref and the fetch fails.
export UPSTREAM_COMMIT="${UPSTREAM_COMMIT:-43446e8680d0f80f8d8acd7dc23381e487b258b4}"
export CODE_CONFIGMAP="mom-bench-code"
export HARNESS_CONFIGMAP="mom-bench-harness"
export JOB_NAME="mom-bench-${RUN_ID}"

kube() { kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" "$@"; }

# The Job's args are a YAML flow sequence, so a category with a space in it stays
# one argument instead of becoming two.
JOB_ARGS="["
for arg in "$@"; do
  JOB_ARGS+="\"${arg//\"/\\\"}\", "
done
JOB_ARGS="${JOB_ARGS%, }]"
export JOB_ARGS

echo "[1/4] code"
kube create configmap "${CODE_CONFIGMAP}" \
  --from-file=collect.py="${here}/collect.py" \
  --from-file=entrypoint.sh="${here}/k8s/entrypoint.sh" \
  --from-file=build_config.py="${here}/../vsr/build_config.py" \
  --from-file=pool.yaml="${here}/../vsr/pool.yaml" \
  --from-file=models.json="${STRATOCLAVE_DEFAULTS}/models.json" \
  --from-file=pricing.json="${STRATOCLAVE_DEFAULTS}/pricing.json" \
  --dry-run=client -o yaml | kube apply -f - > /dev/null

kube create configmap "${HARNESS_CONFIGMAP}" \
  --from-file="${here}/harness" \
  --dry-run=client -o yaml | kube apply -f - > /dev/null
echo "      ${CODE_CONFIGMAP} and ${HARNESS_CONFIGMAP} applied"

echo "[2/4] job ${JOB_NAME}"
# Deleted first so a re-run with the same id replaces the previous attempt rather
# than failing on an immutable field. The results volume is untouched, so the new
# attempt can resume from what the old one wrote.
kube delete job "${JOB_NAME}" --ignore-not-found --wait=true > /dev/null
envsubst < "${here}/k8s/job.yaml" | kube apply -f -

echo "[3/4] waiting for the pod"
for _ in $(seq 1 60); do
  pod="$(kube get pods -l job-name="${JOB_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${pod}" ]] && break
  sleep 2
done
[[ -n "${pod:-}" ]] || { echo "[FAIL] no pod appeared for ${JOB_NAME}" >&2; exit 1; }

echo "[4/4] ${pod}"
cat <<EOF

follow:   kubectl --context "${KUBE_CONTEXT}" -n ${NAMESPACE} logs -f ${pod}
results:  /results/${RUN_ID} on pvc mom-bench-results
fetch:    ./fetch.sh ${RUN_ID}
EOF
