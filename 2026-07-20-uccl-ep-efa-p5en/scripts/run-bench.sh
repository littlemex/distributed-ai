#!/usr/bin/env bash
# run-bench.sh — apply a UCCL-EP microbenchmark job and stream the result.
#
# This is a thin kubectl wrapper (no SSH into nodes): it applies a self-contained
# manifest, waits for rank0 to finish, and prints the parsed dispatch/combine
# numbers. It assumes the USE_DMABUF build is already staged on FSx at
# /fsx/uccl-dmabuf (see scripts/build-uccl.sh and docs/GOTCHAS.md).
#
# Usage:
#   ./run-bench.sh normal        # test_internode.py  (throughput mode)
#   ./run-bench.sh low-latency   # test_low_latency.py (latency mode)
#
# Requires: kubectl context pointing at the target cluster; p5en x2 free (8 GPU
# + 15 EFA each). Reads no AWS creds directly.
set -euo pipefail

MODE="${1:-normal}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

case "$MODE" in
  normal)      MANIFEST="$HERE/manifests/10-internode-bench.yaml" ;;
  low-latency) MANIFEST="$HERE/manifests/11-lowlatency-bench.yaml" ;;
  *) echo "Usage: $0 [normal|low-latency]" >&2; exit 1 ;;
esac

echo "[run] applying $MANIFEST"
kubectl delete pod uccl-bench-rank0 uccl-bench-rank1 --ignore-not-found --wait=false >/dev/null 2>&1 || true
sleep 5
kubectl apply -f "$MANIFEST"

echo "[run] waiting for rank0 to complete (up to 10 min)"
for _ in $(seq 1 60); do
  phase="$(kubectl get pod uccl-bench-rank0 -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  echo "  rank0=$phase"
  [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
  sleep 10
done

echo "[run] === parsed results (rank0) ==="
if [[ "$MODE" == "normal" ]]; then
  kubectl logs uccl-bench-rank0 2>/dev/null | grep -E "Best dispatch|Best combine" || true
else
  kubectl logs uccl-bench-rank0 2>/dev/null | grep -E "rank 0\].*bandwidth" || true
fi

echo "[run] full log: kubectl logs uccl-bench-rank0"
