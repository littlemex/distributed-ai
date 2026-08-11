#!/usr/bin/env bash
# 04-teardown.sh
# Orderly teardown: GPU pods → NodePool → optional Terraform destroy.
#
# Default mode deletes only Kubernetes workloads in the given namespace,
# then removes the Karpenter NodePool so CB nodes are released.
# Pass --destroy to also run `terraform destroy` (removes the entire cluster).
#
# Usage:
#   ./04-teardown.sh --namespace <ns> [--nodepool <name>...] [--destroy] [--yes]
#
# Flags:
#   --namespace  Kubernetes namespace whose GPU pods to drain (required)
#   --nodepool   Karpenter NodePool to delete. Repeatable. When omitted, every NodePool
#                carrying an accelerator device taint is discovered from the cluster.
#   --destroy    Also run `terraform destroy` after Kubernetes cleanup
#   --yes        Skip interactive confirmation, including terraform's own destroy approval
#                (it passes -auto-approve). Required for any non-interactive run — see the
#                comment at the terraform destroy call for what breaks without it.
#
# The pools are DISCOVERED, not assumed. accelerator_pools is a map the reader defines, so there
# is no single pool name this script could default to: a hardcoded default silently matches
# nothing ("NodePool not found — skipping") and leaves the expensive nodes running, which is the
# exact accident this script exists to prevent. A pool counts as an accelerator pool when its
# template carries one of the device taints the Terraform module stamps (nvidia.com/gpu,
# aws.amazon.com/neuron); the CPU pool has no such taint and is left to `terraform destroy`,
# which needs somewhere to run its own final workloads.

set -euo pipefail

NAMESPACE=""
NODEPOOLS=()
RUN_DESTROY=false
AUTO_YES=false

# Device taints the Terraform module puts on accelerator pools. Extend this if a new device type
# is added; a pool whose taint is not listed here is not treated as an accelerator pool.
ACCELERATOR_TAINTS=("nvidia.com/gpu" "aws.amazon.com/neuron")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)   NAMESPACE="$2";        shift 2 ;;
    --nodepool)    NODEPOOLS+=("$2");      shift 2 ;;
    --destroy)     RUN_DESTROY=true;       shift ;;
    --yes)         AUTO_YES=true;          shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$NAMESPACE" ]]; then
  echo "Error: --namespace is required." >&2
  exit 1
fi

# ── Verify the kubectl context targets THIS cluster ───────────────────────────
# Every step below deletes cluster-scoped or namespace-scoped objects (workloads, NodePools)
# and then destroys AWS infrastructure. If the current kubectl context points at a different
# cluster (a stale context from earlier work is easy to leave behind), those deletes hit the
# wrong cluster silently. Resolve the expected cluster name from Terraform output and require
# the active context to reference it. Same guard tests/run-tests.sh already enforces.
CLUSTER_NAME=$(cd "$INFRA_DIR" && terraform output -raw cluster_name 2>/dev/null || true)
if [[ -n "$CLUSTER_NAME" ]]; then
  CTX=$(kubectl config current-context 2>/dev/null || true)
  CTX_CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || true)
  if [[ "$CTX_CLUSTER" != *"$CLUSTER_NAME"* ]]; then
    echo "Error: current kubectl context ($CTX) does not target cluster '$CLUSTER_NAME'" >&2
    echo "       (context cluster: ${CTX_CLUSTER:-none}). Refusing to run destructive steps" >&2
    echo "       against the wrong cluster. Switch context, e.g.:" >&2
    echo "         aws eks update-kubeconfig --name $CLUSTER_NAME --region <region>" >&2
    exit 1
  fi
  echo "kubectl context OK: $CTX (cluster: $CLUSTER_NAME)"
else
  echo "WARNING: could not read cluster_name from 'terraform output' in $INFRA_DIR." >&2
  echo "         Skipping the context-safety check — verify 'kubectl config current-context'" >&2
  echo "         points at the intended cluster before continuing." >&2
fi

# ── Resolve which NodePools to delete ─────────────────────────────────────────
# Ask the cluster rather than assuming a name. Every accelerator pool has to be found: leaving
# one behind means GPU or Neuron instances keep billing after the reader believes teardown ran.
if [[ ${#NODEPOOLS[@]} -eq 0 ]]; then
  TAINTS_CSV=$(IFS=,; echo "${ACCELERATOR_TAINTS[*]}")
  mapfile -t NODEPOOLS < <(
    kubectl get nodepool -o json 2>/dev/null \
      | TAINTS_CSV="$TAINTS_CSV" python3 -c "
import json, os, sys
wanted = set(os.environ['TAINTS_CSV'].split(','))
try:
    items = json.load(sys.stdin).get('items', [])
except Exception:
    sys.exit(0)
for np in items:
    spec = np.get('spec', {}).get('template', {}).get('spec', {})
    keys = {t.get('key') for t in spec.get('taints', [])}
    if keys & wanted:
        print(np['metadata']['name'])
"
  )
  if [[ ${#NODEPOOLS[@]} -eq 0 ]]; then
    echo "No NodePool carries an accelerator device taint (${ACCELERATOR_TAINTS[*]})."
    echo "Nothing to drain. If a pool should have matched, pass it with --nodepool <name>."
  else
    echo "Discovered accelerator NodePool(s): ${NODEPOOLS[*]}"
  fi
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
echo "  NodePool(s): ${NODEPOOLS[*]:-(none found)}"
echo "  Destroy    : $RUN_DESTROY"
echo ""

# ── Step 1: Delete GPU workloads ──────────────────────────────────────────────
echo "Step 1 — Delete GPU pods and workloads in namespace: $NAMESPACE"
if confirm "  Delete all workloads (Deployments, StatefulSets, DaemonSets, Jobs, bare Pods, TrainJobs, MPIJobs) in $NAMESPACE?"; then
  kubectl -n "$NAMESPACE" delete deployment  --all --ignore-not-found=true
  kubectl -n "$NAMESPACE" delete statefulset --all --ignore-not-found=true
  # DaemonSets and bare Pods too: the book's own accelerator verification manifests
  # (nccl-sshd, nccl-probe, neuron-probe, image-prewarm, ...) are DaemonSets or standalone
  # Pods, not Deployments/Jobs, and each pins a GPU/Neuron node. Skipping them leaves the
  # expensive node "not empty" so WhenEmpty never fires — exactly the leak this script exists
  # to prevent. --all covers whatever the reader actually created, not a fixed workshop list.
  kubectl -n "$NAMESPACE" delete daemonset   --all --ignore-not-found=true
  kubectl -n "$NAMESPACE" delete job         --all --ignore-not-found=true
  # TrainJob (Kubeflow Trainer v2) is the book's primary training workload. Delete it too, or its
  # JobSet-managed pods linger and stall NodeClaim drain. Bound the wait so a wedged Trainer
  # controller (unable to clear finalizers) cannot block teardown forever; if the delete times
  # out, strip the finalizers so the CR (and its pods) can go, then continue.
  if ! kubectl -n "$NAMESPACE" delete trainjob --all --ignore-not-found=true --timeout=120s 2>/dev/null; then
    echo "  TrainJob delete timed out — clearing finalizers so teardown can proceed."
    for tj in $(kubectl -n "$NAMESPACE" get trainjob -o name 2>/dev/null); do
      kubectl -n "$NAMESPACE" patch "$tj" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    done
  fi
  kubectl -n "$NAMESPACE" delete mpijob      --all --ignore-not-found=true 2>/dev/null || true
  # Bare Pods not owned by any controller above (e.g. a manually-run probe pod) survive all the
  # --all deletes on higher-level kinds, so sweep them explicitly last.
  kubectl -n "$NAMESPACE" delete pod         --all --ignore-not-found=true 2>/dev/null || true

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
echo "Step 2 — Delete Karpenter NodePool(s): ${NODEPOOLS[*]:-(none)}"
for NODEPOOL_NAME in "${NODEPOOLS[@]:-}"; do
  [[ -z "$NODEPOOL_NAME" ]] && continue
  if kubectl get nodepool "$NODEPOOL_NAME" &>/dev/null; then
    if confirm "  Delete NodePool '$NODEPOOL_NAME'?"; then
      kubectl delete nodepool "$NODEPOOL_NAME" --ignore-not-found=true
      echo "  NodePool '$NODEPOOL_NAME' deleted."
    else
      echo "  Skipped '$NODEPOOL_NAME'."
    fi
  else
    # Only reachable via an explicit --nodepool, since discovery reads live objects. A name the
    # cluster does not have is a typo worth surfacing, not a no-op to pass over quietly.
    echo "  WARNING: NodePool '$NODEPOOL_NAME' not found. If its nodes are still running," >&2
    echo "           they will keep billing. Check: kubectl get nodepool" >&2
  fi
done

# Whether or not a pool was deleted, report what accelerator nodes are still up. A reader who
# sees "Teardown complete" with p4d nodes still listed here knows something did not take.
echo ""
echo "Accelerator nodes still registered:"
kubectl get nodes -o json 2>/dev/null | python3 -c "
import json, sys
try:
    items = json.load(sys.stdin).get('items', [])
except Exception:
    items = []
left = []
for n in items:
    cap = n.get('status', {}).get('capacity', {})
    devs = {k: v for k, v in cap.items()
            if k in ('nvidia.com/gpu', 'aws.amazon.com/neuron')}
    if devs:
        labels = n['metadata'].get('labels', {})
        left.append('  %s  %s  %s' % (
            n['metadata']['name'],
            labels.get('node.kubernetes.io/instance-type', '?'),
            ' '.join('%s=%s' % kv for kv in sorted(devs.items()))))
if left:
    print('\n'.join(left))
    print('  (still billing — they drain asynchronously; watch: kubectl get nodeclaims -w)')
else:
    print('  none')
"

# ── Step 3: Optional terraform destroy ───────────────────────────────────────
if [[ "$RUN_DESTROY" == "true" ]]; then
  echo ""
  echo "Step 3 — Terraform destroy (removes EKS cluster and all AWS resources)"
  echo ""
  echo "!!! This will DELETE the EKS cluster, VPC, and all associated resources. !!!"
  echo "!!! This cannot be undone.                                                !!!"
  echo ""
  if confirm "  Run terraform destroy in $INFRA_DIR?"; then
    # Delete EVERY remaining Karpenter NodePool (monitoring, cpu, any leftover), not just the
    # accelerator ones from Step 2, BEFORE terraform destroy. terraform destroy's internal
    # wait_for_node_drain polls until ALL NodeClaims reach zero; but a still-present NodePool
    # keeps Karpenter launching replacement nodes to satisfy pending pods (e.g. the monitoring
    # stack), so the wait never converges and destroy deadlocks. The monitoring NodePool in
    # particular is intentionally NOT ordered before the drain-wait in the Terraform graph (it
    # would form a dependency cycle), so clearing it here — outside the graph — is the fix.
    # Verified live: without this, terraform destroy hangs on a perpetually-recreated
    # monitoring NodeClaim. Best-effort: ignore-not-found and never fail teardown over it.
    echo "  Deleting all remaining Karpenter NodePools so Karpenter stops launching nodes during destroy..."
    kubectl delete nodepool --all --ignore-not-found=true --timeout=120s 2>/dev/null || {
      echo "  NodePool delete timed out — clearing finalizers so destroy can proceed."
      for np in $(kubectl get nodepool -o name 2>/dev/null); do
        kubectl patch "$np" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
      done
    }
    cd "$INFRA_DIR"
    # No explicit -var-file: terraform auto-loads terraform.tfvars and *.auto.tfvars, which is
    # exactly what `terraform apply` used, so destroy evaluates the same region / cluster_name /
    # accelerator_pools. (An earlier version referenced a terraform.tfvars.local that no script
    # ever creates — a dead branch that risked destroying with default var values if it had.)
    # Pass -auto-approve through when --yes was given. Without this, --yes suppresses only THIS
    # script's own prompts and terraform then asks its own "Do you really want to destroy all
    # resources?" on stdin — which in any non-interactive context (nohup, CI, a background run)
    # gets EOF and fails the whole destroy AFTER the Kubernetes cleanup has already happened.
    # That is the worst possible place to stop: the NodePools are gone but the cluster is not.
    if [[ "$AUTO_YES" == "true" ]]; then
      terraform destroy -auto-approve
    else
      terraform destroy
    fi
  else
    echo "  Skipped. Run manually: cd $INFRA_DIR && terraform destroy"
  fi
fi

echo ""
echo "=== Teardown complete ==="
