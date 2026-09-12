#!/usr/bin/env bash
# Copy a run's results out of the cluster.
#
#   ./fetch.sh <run-id> [destination]
#
# The results volume is shared, so this works while the run is still going: a
# partial matrix is useful, and watching the per-member failure rate early is how
# a bad run gets stopped before it spends the balance.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${KUBE_CONTEXT:?set KUBE_CONTEXT to the cluster running the router}"
[[ $# -ge 1 ]] || { echo "usage: $0 <run-id> [destination]" >&2; exit 2; }

RUN_ID="$1"
DEST="${2:-${here}/results/${RUN_ID}}"
NAMESPACE="${NAMESPACE:-vsr-bench}"
READER="mom-bench-reader"

kube() { kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" "$@"; }

# A separate reader pod rather than the Job's own: the Job may have finished and
# gone, and copying out of a running measurement's container competes with it.
if ! kube get pod "${READER}" > /dev/null 2>&1; then
  kube apply -f - > /dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${READER}
  labels:
    app.kubernetes.io/name: mom-bench
spec:
  containers:
    - name: reader
      image: busybox:1.36
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: results
          mountPath: /results
          readOnly: true
      resources:
        requests: {cpu: 50m, memory: 64Mi}
        limits: {cpu: 200m, memory: 128Mi}
  volumes:
    - name: results
      persistentVolumeClaim:
        claimName: mom-bench-results
EOF
  kube wait --for=condition=Ready "pod/${READER}" --timeout=180s > /dev/null
fi

mkdir -p "${DEST}"
kube cp "${READER}:/results/${RUN_ID}" "${DEST}" > /dev/null
echo "[OK] ${RUN_ID} -> ${DEST}"
find "${DEST}" -type f -name '*.jsonl' -exec sh -c 'printf "    %-40s %s rows\n" "$(basename "$1")" "$(wc -l < "$1" | tr -d " ")"' _ {} \;
