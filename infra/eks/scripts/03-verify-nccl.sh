#!/usr/bin/env bash
# 03-verify-nccl.sh
# Run a 2-node NCCL all_reduce_perf test over EFA and report busbw.
#
# This script applies a self-contained MPIJob manifest, waits for completion,
# streams the launcher log, and prints the peak busbw from the result table.
# It is read-only from an AWS perspective — only kubectl resources are created.
#
# Usage:
#   ./03-verify-nccl.sh \
#     --namespace <ns> \
#     --image <nccl-tests-image> \
#     [--nodes 2] \
#     [--gpus-per-node 8] \
#     [--efa-per-node 15]
#
# Requirements:
#   - kubectl, helm, python3
#   - MPI Operator (mpi-operator) already installed in the cluster
#   - Nodes provisioned with EFA (vpc.amazonaws.com/efa resource available)
#   - Image must include nccl-tests binary at /opt/nccl-tests/build/all_reduce_perf
#
# Verified image naming convention (from provenance.md):
#   <account>.dkr.ecr.<region>.amazonaws.com/nccl-tests:cuda12.8.1-efa1.42.0-ofiv1.16.0-ncclv2.27.5-1-testsv2.16.4
#
# Expected result (p5en/p5, 2 nodes x 8 GPU, 1 GB message):
#   busbw ~514 GB/s  (EFA over RDMA)
#   busbw ~734 GB/s  (single node, NVLink only)

set -euo pipefail

NAMESPACE="default"
IMAGE=""
NUM_NODES=2
GPUS_PER_NODE=8
EFA_PER_NODE=""
JOB_NAME="nccl-verify-$(date +%s)"
TIMEOUT_SECONDS=600

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)      NAMESPACE="$2";      shift 2 ;;
    --image)          IMAGE="$2";          shift 2 ;;
    --nodes)          NUM_NODES="$2";      shift 2 ;;
    --gpus-per-node)  GPUS_PER_NODE="$2";  shift 2 ;;
    --efa-per-node)   EFA_PER_NODE="$2";   shift 2 ;;
    --job-name)       JOB_NAME="$2";       shift 2 ;;
    --timeout)        TIMEOUT_SECONDS="$2";shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$IMAGE" ]]; then
  echo "Error: --image is required." >&2
  echo "  Example: $0 --namespace my-ns --image <ACCOUNT_ID>.dkr.ecr.us-east-2.amazonaws.com/nccl-tests:latest" >&2
  exit 1
fi

# Derive schedulable EFA count if not explicitly set. On multi-card instances
# (p5/p5en/trn2), card 0 carries the node IP and is NOT advertised as EFA, so
# the schedulable count is (total_cards - 1). Querying a node's allocatable is
# the most reliable source; fall back to 15 (p5en default) if no EFA node found.
if [[ -z "$EFA_PER_NODE" ]]; then
  EFA_PER_NODE=$(kubectl get nodes -l "node-role=gpu-p5en" \
    -o jsonpath='{.items[0].status.allocatable.vpc\.amazonaws\.com/efa}' 2>/dev/null || true)
  if [[ -z "$EFA_PER_NODE" ]]; then
    EFA_PER_NODE=15
    echo "Warning: could not query EFA allocatable from nodes; defaulting to $EFA_PER_NODE" >&2
  fi
fi

TOTAL_PROCS=$(( NUM_NODES * GPUS_PER_NODE ))

echo "=== NCCL Verification: 2-node all_reduce_perf ==="
echo "  Namespace      : $NAMESPACE"
echo "  Image          : $IMAGE"
echo "  Nodes          : $NUM_NODES"
echo "  GPUs/node      : $GPUS_PER_NODE"
echo "  EFA/node       : $EFA_PER_NODE"
echo "  Total ranks    : $TOTAL_PROCS"
echo "  Job name       : $JOB_NAME"
echo ""

# ── Apply MPIJob manifest ─────────────────────────────────────────────────────
kubectl apply -f - <<EOF
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
spec:
  slotsPerWorker: $GPUS_PER_NODE
  runPolicy:
    cleanPodPolicy: Running
    ttlSecondsAfterFinished: 300
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      restartPolicy: OnFailure
      template:
        spec:
          containers:
          - name: launcher
            image: $IMAGE
            command:
            - mpirun
            - --allow-run-as-root
            - -np
            - "$TOTAL_PROCS"
            - -x
            - FI_PROVIDER=efa
            - -x
            - FI_EFA_USE_DEVICE_RDMA=1
            - -x
            - FI_EFA_FORK_SAFE=1
            - -x
            - "NCCL_SOCKET_IFNAME=^lo,docker,veth"
            - -x
            - NCCL_DEBUG=WARN
            - /opt/nccl-tests/build/all_reduce_perf
            - -b
            - "8"
            - -e
            - 1G
            - -f
            - "2"
            - -g
            - "1"
    Worker:
      replicas: $NUM_NODES
      restartPolicy: OnFailure
      template:
        spec:
          tolerations:
          - { key: nvidia.com/gpu,          operator: Exists, effect: NoSchedule }
          - { key: vpc.amazonaws.com/efa,   operator: Exists, effect: NoSchedule }
          - { key: capacity-reservation,    operator: Exists, effect: NoSchedule }
          containers:
          - name: worker
            image: $IMAGE
            securityContext:
              privileged: true
            resources:
              limits:
                nvidia.com/gpu: "$GPUS_PER_NODE"
                vpc.amazonaws.com/efa: "$EFA_PER_NODE"
            env:
            - { name: FI_PROVIDER,             value: "efa" }
            - { name: FI_EFA_USE_DEVICE_RDMA,  value: "1" }
            - { name: FI_EFA_FORK_SAFE,        value: "1" }
            - { name: NCCL_SOCKET_IFNAME,      value: "^lo,docker,veth" }
EOF

echo "MPIJob '$JOB_NAME' applied. Waiting for launcher pod..."

# ── Wait for launcher pod ─────────────────────────────────────────────────────
LAUNCHER_POD=""
ELAPSED=0
while [[ -z "$LAUNCHER_POD" ]]; do
  LAUNCHER_POD=$(kubectl -n "$NAMESPACE" get pods \
    -l training.kubeflow.org/job-name="$JOB_NAME",training.kubeflow.org/replica-type=launcher \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$LAUNCHER_POD" ]]; then
    sleep 5
    ELAPSED=$(( ELAPSED + 5 ))
    if [[ $ELAPSED -ge $TIMEOUT_SECONDS ]]; then
      echo "Timed out waiting for launcher pod." >&2; exit 1
    fi
  fi
done

echo "Launcher pod: $LAUNCHER_POD"
echo "Streaming logs (Ctrl-C to detach — job will keep running)..."
echo ""

kubectl -n "$NAMESPACE" logs -f "$LAUNCHER_POD" 2>/dev/null || true

echo ""
echo "=== Job status ==="
kubectl -n "$NAMESPACE" get mpijob "$JOB_NAME" -o wide

echo ""
echo "To extract peak busbw from logs:"
echo "  kubectl -n $NAMESPACE logs $LAUNCHER_POD | grep -E '^\s+[0-9]' | awk 'END{print \"peak busbw:\", \$NF, \"GB/s\"}'"
echo ""
echo "Cleanup (optional):"
echo "  kubectl -n $NAMESPACE delete mpijob $JOB_NAME"
