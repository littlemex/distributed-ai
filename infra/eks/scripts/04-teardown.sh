#!/usr/bin/env bash
# 04-teardown.sh
# Orderly teardown: GPU pods → NodePool → optional Terraform destroy.
#
# Default mode deletes only Kubernetes workloads in the given namespace,
# then removes the Karpenter NodePool so CB nodes are released.
# Pass --destroy to also run `terraform destroy` (removes the entire cluster).
#
# Usage:
#   ./04-teardown.sh --namespace <ns> [--destroy] [--yes]
#
# Flags:
#   --namespace  Kubernetes namespace whose GPU pods to drain (required)
#   --nodepool   Karpenter NodePool name to delete (default: gpu-training)
#   --destroy    Also run `terraform destroy` after Kubernetes cleanup
#   --yes        Skip interactive confirmation (use in CI with caution)

set -euo pipefail

NAMESPACE=""
NODEPOOL_NAME="gpu-training"
RUN_DESTROY=false
AUTO_YES=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)   NAMESPACE="$2";        shift 2 ;;
    --nodepool)    NODEPOOL_NAME="$2";     shift 2 ;;
    --destroy)     RUN_DESTROY=true;       shift ;;
    --yes)         AUTO_YES=true;          shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$NAMESPACE" ]]; then
  echo "Error: --namespace is required." >&2
  exit 1
fi

confirm() {
  local MSG="$1"
  if [[ "$AUTO_YES" == "true" ]]; then
    echo "$MSG [auto-yes]"
    return 0
  fi
  read -rp "$MSG [y/N] " ANS
  [[ "${ANS,,}" == "y" ]]
}

echo "=== Teardown Plan ==="
echo "  Namespace  : $NAMESPACE"
echo "  NodePool   : $NODEPOOL_NAME"
echo "  Destroy    : $RUN_DESTROY"
echo ""

# ── Step 1: Delete GPU workloads ──────────────────────────────────────────────
echo "Step 1 — Delete GPU pods and workloads in namespace: $NAMESPACE"
if confirm "  Delete all Deployments, StatefulSets, Jobs, PyTorchJobs, and MPIJobs in $NAMESPACE?"; then
  kubectl -n "$NAMESPACE" delete deployment  --all --ignore-not-found=true
  kubectl -n "$NAMESPACE" delete statefulset --all --ignore-not-found=true
  kubectl -n "$NAMESPACE" delete job         --all --ignore-not-found=true
  # PyTorchJob is the book's primary training workload (Kubeflow Training Operator, etcd
  # rendezvous). Delete it too, or its Worker pods linger and stall NodeClaim drain.
  kubectl -n "$NAMESPACE" delete pytorchjob  --all --ignore-not-found=true 2>/dev/null || true
  kubectl -n "$NAMESPACE" delete mpijob      --all --ignore-not-found=true 2>/dev/null || true

  echo "  Waiting for pods to terminate..."
  ELAPSED=0
  while true; do
    GPU_PODS=$(kubectl -n "$NAMESPACE" get pods \
      -o json 2>/dev/null \
      | python3 -c "
import sys, json
pods = json.load(sys.stdin)['items']
running = [p for p in pods
           if p.get('status', {}).get('phase') in ('Running', 'Pending')]
print(len(running))
" 2>/dev/null || echo "0")
    if [[ "$GPU_PODS" -eq 0 ]]; then
      echo "  All pods terminated."
      break
    fi
    echo "  Still $GPU_PODS pod(s) running... (${ELAPSED}s)"
    sleep 10
    ELAPSED=$(( ELAPSED + 10 ))
    if [[ $ELAPSED -ge 300 ]]; then
      echo "  Warning: pods still running after 5 minutes. Proceeding anyway." >&2
      break
    fi
  done
else
  echo "  Skipped."
fi

# ── Verify GPU release ────────────────────────────────────────────────────────
echo ""
echo "GPU usage after cleanup:"
kubectl get pods -A -o json 2>/dev/null | python3 -c "
import sys, json
pods = json.load(sys.stdin)['items']
gpu_pods = []
for p in pods:
    if p.get('status', {}).get('phase') not in ('Running',):
        continue
    gpus = sum(
        int(c.get('resources', {}).get('requests', {}).get('nvidia.com/gpu', 0))
        for c in p.get('spec', {}).get('containers', [])
    )
    if gpus > 0:
        gpu_pods.append(f\"  {p['metadata']['namespace']}/{p['metadata']['name']}  gpu={gpus}\")
if gpu_pods:
    print('Active GPU pods:')
    print('\n'.join(gpu_pods))
else:
    print('  No GPU pods running (safe to proceed).')
"

# ── Step 2: Delete NodePool ───────────────────────────────────────────────────
echo ""
echo "Step 2 — Delete Karpenter NodePool: $NODEPOOL_NAME"
if kubectl get nodepool "$NODEPOOL_NAME" &>/dev/null; then
  if confirm "  Delete NodePool '$NODEPOOL_NAME'?"; then
    kubectl delete nodepool "$NODEPOOL_NAME" --ignore-not-found=true
    echo "  NodePool deleted. CB nodes will be released when the reservation expires."
  else
    echo "  Skipped."
  fi
else
  echo "  NodePool '$NODEPOOL_NAME' not found — skipping."
fi

# ── Step 3: Optional terraform destroy ───────────────────────────────────────
if [[ "$RUN_DESTROY" == "true" ]]; then
  echo ""
  echo "Step 3 — Terraform destroy (removes EKS cluster and all AWS resources)"
  echo ""
  echo "!!! This will DELETE the EKS cluster, VPC, and all associated resources. !!!"
  echo "!!! This cannot be undone.                                                !!!"
  echo ""
  if confirm "  Run terraform destroy in $INFRA_DIR?"; then
    TFVARS_LOCAL="$INFRA_DIR/terraform.tfvars.local"
    EXTRA_ARGS=""
    if [[ -f "$TFVARS_LOCAL" ]]; then
      EXTRA_ARGS="-var-file=terraform.tfvars.local"
    fi
    cd "$INFRA_DIR"
    terraform destroy $EXTRA_ARGS
  else
    echo "  Skipped. Run manually: cd $INFRA_DIR && terraform destroy"
  fi
fi

echo ""
echo "=== Teardown complete ==="
