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
#     [--gpus-per-node <n>|auto] \
#     [--efa-per-node <n>|auto] \
#     [--node-role <karpenter pool name>]
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
# GPU and EFA counts default to "auto": they are READ FROM THE LIVE NODES' allocatable
# (the same values the device plugins advertise) instead of being hardcoded. The EFA count
# in particular is instance-family specific — p5en advertises 15 (16 cards minus card 0),
# p4d advertises 3 (4 minus card 0) — so a fixed number silently leaves the worker Pods
# Pending forever on any family it was not written for. Pass an explicit number to override.
#
# Reference results (2 nodes, 1 GB message, EFA over RDMA):
#   p5en.48xlarge (H200 x8, EFA 15) : busbw ~514 GB/s   [single node NVLink only: ~734 GB/s]
#   p4d.24xlarge  (A100 x8, EFA 3)  : busbw ~130 GB/s

set -euo pipefail

NAMESPACE="default"
IMAGE=""
NUM_NODES=2
GPUS_PER_NODE="auto"
EFA_PER_NODE="auto"
NODE_ROLE=""
JOB_NAME="nccl-verify-$(date +%s)"
TIMEOUT_SECONDS=600

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)      NAMESPACE="$2";      shift 2 ;;
    --image)          IMAGE="$2";          shift 2 ;;
    --nodes)          NUM_NODES="$2";      shift 2 ;;
    --gpus-per-node)  GPUS_PER_NODE="$2";  shift 2 ;;
    --efa-per-node)   EFA_PER_NODE="$2";   shift 2 ;;
    --node-role)      NODE_ROLE="$2";      shift 2 ;;
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

# ── Discover per-node GPU / EFA counts from the live cluster ───────────────────
# Reads .status.allocatable — what the device plugins actually advertise — rather than
# assuming an instance family. Restrict to the target Karpenter pool when --node-role is
# given (node-role=<pool name> is the label this module puts on every pool's nodes), else
# consider any EFA-capable node. The MINIMUM across candidate nodes is used so a mixed
# cluster cannot produce a request that one of the chosen workers can't satisfy.
discover_allocatable() {
  local resource="$1" selector=""
  [[ -n "$NODE_ROLE" ]] && selector="-l node-role=$NODE_ROLE"
  # shellcheck disable=SC2086
  kubectl get nodes $selector \
    -o jsonpath="{range .items[*]}{.status.allocatable['${resource}']}{'\n'}{end}" 2>/dev/null \
    | grep -E '^[0-9]+$' | sort -n | head -1 || true
}

if [[ "$GPUS_PER_NODE" == "auto" ]]; then
  GPUS_PER_NODE=$(discover_allocatable 'nvidia\.com/gpu')
  if [[ -z "$GPUS_PER_NODE" || "$GPUS_PER_NODE" == "0" ]]; then
    echo "Error: could not discover nvidia.com/gpu from node allocatable." >&2
    echo "  No GPU node is Ready yet (Karpenter may still be provisioning), or the NVIDIA" >&2
    echo "  device plugin is not advertising. Pass --gpus-per-node <n> to override." >&2
    exit 1
  fi
  echo "[auto] GPUs/node discovered from node allocatable: $GPUS_PER_NODE"
fi

if [[ "$EFA_PER_NODE" == "auto" ]]; then
  EFA_PER_NODE=$(discover_allocatable 'vpc\.amazonaws\.com/efa')
  if [[ -z "$EFA_PER_NODE" || "$EFA_PER_NODE" == "0" ]]; then
    echo "Error: could not discover vpc.amazonaws.com/efa from node allocatable." >&2
    echo "  Either no EFA node is Ready yet, or the EFA device plugin is not advertising." >&2
    echo "  Cross-check with: terraform output accelerator_pool_efa_schedulable" >&2
    echo "  Pass --efa-per-node <n> to override." >&2
    exit 1
  fi
  echo "[auto] EFA/node discovered from node allocatable: $EFA_PER_NODE"
fi

TOTAL_PROCS=$(( NUM_NODES * GPUS_PER_NODE ))

echo "=== NCCL Verification: ${NUM_NODES}-node all_reduce_perf ==="
echo "  Namespace      : $NAMESPACE"
echo "  Image          : $IMAGE"
echo "  Nodes          : $NUM_NODES"
echo "  Node role      : ${NODE_ROLE:-(any EFA node)}"
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
            # INFO (not WARN) is required: the "NET/OFI Selected provider is efa" line that
            # proves EFA is in use — rather than a silent TCP fallback — is logged at INFO.
            - NCCL_DEBUG=INFO
            - -x
            # Limit INFO to the subsystems that carry the provider/topology evidence, so the
            # launcher log stays readable instead of emitting every NCCL INFO line.
            - NCCL_DEBUG_SUBSYS=INIT,NET
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
          hostNetwork: true
          dnsPolicy: ClusterFirstWithHostNet
$(if [[ -n "$NODE_ROLE" ]]; then
  printf '          nodeSelector:\n            node-role: %s\n' "$NODE_ROLE"
fi)          # Force one worker per node: NCCL must cross the network for EFA to be exercised.
          # Without this the scheduler may stack both workers on one node and the test would
          # measure NVLink while reporting nothing about EFA.
          affinity:
            podAntiAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
              - labelSelector:
                  matchLabels:
                    training.kubeflow.org/job-name: $JOB_NAME
                    training.kubeflow.org/replica-type: worker
                topologyKey: kubernetes.io/hostname
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
                # Discovered from node allocatable (see discover_allocatable above), NOT a
                # fixed 16: card 0 carries the node IP and is never advertised as EFA, so the
                # schedulable count is family specific (p5en 15, p4d 3). Over-requesting here
                # leaves the worker Pods Pending with no error.
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
