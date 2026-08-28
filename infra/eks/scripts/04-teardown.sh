#!/usr/bin/env bash
# 04-teardown.sh
# Orderly teardown: GPU pods → NodePool → optional Terraform destroy.
#
# Default mode deletes only Kubernetes workloads in the given namespace,
# then removes the Karpenter NodePool so CB nodes are released.
# Pass --destroy to also run `terraform destroy` (removes the entire cluster).
#
# Usage:
#   ./04-teardown.sh --namespace <ns> [--nodepool <name>...] [--delete-pvcs] [--destroy] [--yes]
#
# Flags:
#   --namespace   Kubernetes namespace whose GPU pods to drain (required)
#   --nodepool    Karpenter NodePool to delete. Repeatable. When omitted, every NodePool
#                 carrying an accelerator device taint is discovered from the cluster.
#   --delete-pvcs Also delete every PersistentVolumeClaim in the namespace after the
#                 workloads are gone. This is storage-agnostic (FSx for Lustre, FSx for
#                 OpenZFS, EFS — any PVC in the namespace), so it is not tied to one volume.
#                 The static PVs are Retain, so the underlying filesystem/data is NOT deleted
#                 by this; only the PVC (the binding) is removed and the PV goes to Released.
#                 Guarded by its own confirmation because a still-running pod that uses the
#                 PVC will make the delete hang on the pvc-protection finalizer.
#   --destroy     Also run `terraform destroy` after Kubernetes cleanup
#   --yes         Skip interactive confirmation, including terraform's own destroy approval
#                 (it passes -auto-approve). Required for any non-interactive run — see the
#                 comment at the terraform destroy call for what breaks without it.
#   --ignore-vpc-dependents
#                 Run destroy even when the VPC still holds objects this state does not own.
#                 Those make the last step of destroy fail on DependencyViolation, so the default
#                 is to name them and stop before an hour is spent finding out.
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
DELETE_PVCS=false
IGNORE_VPC_DEPENDENTS=false

# Device taints the Terraform module puts on accelerator pools. Extend this if a new device type
# is added; a pool whose taint is not listed here is not treated as an accelerator pool.
ACCELERATOR_TAINTS=("nvidia.com/gpu" "aws.amazon.com/neuron")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)   NAMESPACE="$2";        shift 2 ;;
    --nodepool)    NODEPOOLS+=("$2");      shift 2 ;;
    --delete-pvcs) DELETE_PVCS=true;       shift ;;
    --destroy)     RUN_DESTROY=true;       shift ;;
    --yes)         AUTO_YES=true;          shift ;;
    --ignore-vpc-dependents) IGNORE_VPC_DEPENDENTS=true; shift ;;
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
  # Match the EKS ARN suffix "cluster/<NAME>", not a bare substring: a substring test would
  # let "train" match a stale "train-staging" context and pass the guard on the wrong cluster.
  if [[ "$CTX_CLUSTER" != *"cluster/$CLUSTER_NAME" && "$CTX_CLUSTER" != "$CLUSTER_NAME" ]]; then
    echo "Error: current kubectl context ($CTX) does not target cluster '$CLUSTER_NAME'" >&2
    echo "       (context cluster: ${CTX_CLUSTER:-none}). Refusing to run destructive steps" >&2
    echo "       against the wrong cluster. Switch context, e.g.:" >&2
    echo "         aws eks update-kubeconfig --name $CLUSTER_NAME --region <region>" >&2
    exit 1
  fi
  echo "kubectl context OK: $CTX (cluster: $CLUSTER_NAME)"
else
  # Could not resolve the cluster name (no terraform init/state, or output missing). This is
  # exactly when the guard matters most, so do NOT silently proceed: fail in non-interactive
  # runs, and require an explicit confirmation interactively.
  echo "WARNING: could not read cluster_name from 'terraform output' in $INFRA_DIR." >&2
  echo "         The context-safety check cannot run. Verify 'kubectl config current-context'" >&2
  echo "         points at the intended cluster before continuing." >&2
  if [[ "$AUTO_YES" == "true" ]]; then
    echo "Error: refusing to run destructive steps with --yes while the cluster context is" >&2
    echo "       unverifiable. Run 'terraform init' in $INFRA_DIR, or drop --yes to confirm." >&2
    exit 1
  fi
  read -rp "Continue against context '$(kubectl config current-context 2>/dev/null)'? [y/N] " ANS
  [[ "${ANS,,}" == "y" ]] || { echo "Aborted."; exit 1; }
fi

# The VPC and region the AWS-side checks below need. Read from the state rather than the
# environment: AWS_REGION may point somewhere else entirely (the state bucket's region, a leftover
# export), and a check that looks in the wrong region reports "nothing here" — the one answer that
# must never be wrong. Empty when the state cannot be read, and every use is guarded on that.
VPC_ID=$(cd "$INFRA_DIR" && terraform output -raw vpc_id 2>/dev/null || true)
REGION=$(cd "$INFRA_DIR" && terraform output -raw region 2>/dev/null || true)

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
echo "  Namespace   : $NAMESPACE"
echo "  NodePool(s) : ${NODEPOOLS[*]:-(none found)}"
echo "  Delete PVCs : $DELETE_PVCS"
echo "  Destroy     : $RUN_DESTROY"
echo ""

# ── Step 1: Delete GPU workloads ──────────────────────────────────────────────
echo "Step 1 — Delete GPU pods and workloads in namespace: $NAMESPACE"
if confirm "  Delete all workloads (Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs, CronJobs, bare Pods, TrainJobs, MPIJobs) in $NAMESPACE?"; then
  # --wait=false on every delete: kubectl delete defaults to --wait=true, which blocks until
  # the objects are gone. A pod stuck Terminating on a finalizer (exactly the orphaned-Job-pod
  # case handled below) would then hang THIS command forever, before we ever reach the bounded
  # "wait for pods to terminate" poll loop. Issue the deletes async and let that loop observe.
  kubectl -n "$NAMESPACE" delete deployment  --all --ignore-not-found=true --wait=false
  kubectl -n "$NAMESPACE" delete statefulset --all --ignore-not-found=true --wait=false
  # DaemonSets, ReplicaSets, and bare Pods too: the book's own accelerator verification manifests
  # (nccl-sshd, nccl-probe, neuron-probe, image-prewarm, ...) are DaemonSets or standalone
  # Pods, not Deployments/Jobs, and each pins a GPU/Neuron node. A bare ReplicaSet would also
  # recreate its pods after a pod-only sweep, keeping the node non-empty. Skipping any of these
  # leaves the expensive node "not empty" so WhenEmpty never fires — exactly the leak this
  # script exists to prevent. --all covers whatever the reader actually created.
  kubectl -n "$NAMESPACE" delete daemonset   --all --ignore-not-found=true --wait=false
  kubectl -n "$NAMESPACE" delete replicaset  --all --ignore-not-found=true --wait=false 2>/dev/null || true
  kubectl -n "$NAMESPACE" delete cronjob      --all --ignore-not-found=true --wait=false 2>/dev/null || true
  kubectl -n "$NAMESPACE" delete job         --all --ignore-not-found=true --wait=false
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
  kubectl -n "$NAMESPACE" delete mpijob      --all --ignore-not-found=true --wait=false 2>/dev/null || true
  # Bare Pods not owned by any controller above (e.g. a manually-run probe pod) survive all the
  # --all deletes on higher-level kinds, so sweep them explicitly last.
  kubectl -n "$NAMESPACE" delete pod         --all --ignore-not-found=true --wait=false 2>/dev/null || true

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

# ── Step 1b: (optional) Delete PVCs ───────────────────────────────────────────
# Storage-agnostic: removes every PVC in the namespace (FSx for Lustre, FSx for OpenZFS, EFS,
# whatever the reader created), not a hardcoded FSx claim name. Whether the DATA survives a PVC
# delete depends on the bound PV's persistentVolumeReclaimPolicy, NOT on this script: Retain
# (this module's static PVs) keeps the volume and moves the PV to Released; Delete (e.g. a
# dynamically-provisioned gp3 PVC) deletes the backing volume and its data. So we inspect each
# PVC's reclaim policy first and warn loudly if any is Delete — never print an unconditional
# "data is safe". A PVC delete also HANGS on the kubernetes.io/pvc-protection finalizer while a
# pod still uses it; Step 1 deleted the namespace's pods, but one stuck Terminating (an orphaned
# Job pod whose batch/job-tracking finalizer no controller clears) keeps the PVC pinned, so we
# bound the wait and, on timeout, REPORT the holding pods instead of blocking forever.
if [[ "$DELETE_PVCS" == "true" ]]; then
  echo ""
  echo "Step 1b — Delete PersistentVolumeClaims in namespace: $NAMESPACE"
  PVCS=$(kubectl -n "$NAMESPACE" get pvc -o name 2>/dev/null || true)
  if [[ -z "$PVCS" ]]; then
    echo "  No PVCs in $NAMESPACE. Nothing to delete."
  else
    # Enumerate each PVC with the reclaim policy of its bound PV so the operator sees exactly
    # which deletions destroy data. HAS_DELETE flips the confirmation to an explicit red flag.
    echo "  PVCs in $NAMESPACE (and the reclaim policy of the bound PV):"
    HAS_DELETE=false
    while IFS= read -r pvc; do
      [[ -z "$pvc" ]] && continue
      pvc_name="${pvc#persistentvolumeclaim/}"
      pv=$(kubectl -n "$NAMESPACE" get pvc "$pvc_name" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
      policy=""
      [[ -n "$pv" ]] && policy=$(kubectl get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null || true)
      if [[ "$policy" == "Delete" ]]; then
        echo "    $pvc_name  (PV: ${pv:-none}, reclaim: Delete)  <-- DATA WILL BE DELETED"
        HAS_DELETE=true
      else
        echo "    $pvc_name  (PV: ${pv:-none}, reclaim: ${policy:-unknown})"
      fi
    done <<< "$PVCS"
    if [[ "$HAS_DELETE" == "true" ]]; then
      echo "  WARNING: one or more PVCs are bound to a PV with reclaimPolicy=Delete." >&2
      echo "           Deleting those PVCs DESTROYS the underlying volume and its data." >&2
    else
      echo "  All bound PVs are Retain: deleting the PVCs removes only the binding (PV -> Released)."
    fi
    if confirm "  Delete ALL PVCs in $NAMESPACE? (destructive — see reclaim policies above)"; then
      # --wait=false: issue the deletes, then poll, so a finalizer hang is visible and bounded.
      kubectl -n "$NAMESPACE" delete pvc --all --ignore-not-found=true --wait=false 2>/dev/null || true
      echo "  Waiting for PVCs to finish deleting..."
      PVC_ELAPSED=0
      while true; do
        REMAINING=$(kubectl -n "$NAMESPACE" get pvc -o name 2>/dev/null | grep -c . || true)
        if [[ "$REMAINING" -eq 0 ]]; then
          echo "  All PVCs deleted."
          break
        fi
        if [[ $PVC_ELAPSED -ge 120 ]]; then
          # Don't block teardown. Surface WHY it is stuck: which pods still hold a PVC. The
          # operator clears those pods (see the book chapter on stuck Terminating pods), then
          # re-runs. We deliberately do NOT auto-strip pvc-protection finalizers: that would
          # orphan a volume still mounted by a live pod.
          echo "  Warning: $REMAINING PVC(s) still deleting after 2 minutes." >&2
          echo "  Pods still referencing a PVC in $NAMESPACE (delete these, then re-run):" >&2
          kubectl -n "$NAMESPACE" get pods -o json 2>/dev/null | python3 -c "
import sys, json
try:
    pods = json.load(sys.stdin).get('items', [])
except Exception:
    pods = []
hits = []
for p in pods:
    for v in p.get('spec', {}).get('volumes', []):
        if 'persistentVolumeClaim' in v:
            hits.append('    %s (%s)' % (p['metadata']['name'], p.get('status', {}).get('phase')))
            break
print('\n'.join(hits) if hits else '    (none — the PVC finalizer may be clearing; re-check with: kubectl get pvc -n $NAMESPACE)')
" 2>/dev/null || true
          break
        fi
        echo "  Still $REMAINING PVC(s)... (${PVC_ELAPSED}s)"
        sleep 10
        PVC_ELAPSED=$(( PVC_ELAPSED + 10 ))
      done
    else
      echo "  Skipped PVC deletion."
    fi
  fi
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

# ── Step 2b: name what the VPC holds that this Terraform state does not own ──
# Anything living in the cluster's subnets that Terraform did not create will block the subnet and
# security-group deletes at the very END of `terraform destroy`, and the error AWS returns names
# only the object it could not delete — never the dependent that held it:
#
#   Error: deleting Security Group (sg-05d7...): DependencyViolation: resource sg-05d7... has a
#   dependent object
#
# Measured 2026-08-28 on a real teardown: subnet deletes sat at "Still destroying..." for 15
# minutes, then failed that way three times over. The dependents turned out to be an S3 Files
# filesystem's mount-target ENIs and the security group they used, all created outside this state
# by unrelated work in the same VPC. Finding that took a manual crawl through describe-network-
# interfaces and describe-security-group-rules — which is exactly the crawl this step now does
# up front, before an hour is spent discovering that it was needed.
#
# It reports rather than deletes. A mount target belongs to somebody's filesystem, and this script
# is not entitled to remove another team's storage plumbing on the way to deleting a cluster; the
# operator decides. What it will not do is let the run start and fail an hour later with an error
# that names nothing.
vpc_dependents_report() {
  local vpc="$1" region="$2"
  local state_ids
  # Every id/arn/identifier this state knows, so "owned" is answered from the state rather than
  # from a name pattern. The profiling installer, for instance, legitimately puts an S3 Files
  # mount target in this VPC — that one is in the state and must not be reported as foreign.
  state_ids="$(terraform -chdir="$INFRA_DIR" show -json 2>/dev/null | python3 -c "
import json, sys
def walk(v, out):
    if isinstance(v, dict):
        for k, x in v.items():
            if k in ('id', 'arn', 'identifier', 'group_id', 'security_group_id') and isinstance(x, str):
                out.add(x)
            walk(x, out)
    elif isinstance(v, list):
        for x in v:
            walk(x, out)
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
out = set()
walk(doc.get('values', {}), out)
print('\n'.join(sorted(out)))
" 2>/dev/null || true)"

  # AWS creates ENIs on behalf of things this state DOES own, and gives them ids the state never
  # sees: a NAT gateway's ENI, the EKS control plane's cross-account ENIs, and every node's primary
  # and CNI-secondary ENIs. Matching on the ENI id alone therefore reported a perfectly clean
  # cluster as full of foreign objects — verified live on a cluster with nothing but its own nodes,
  # which listed the node ENIs, the control-plane ENIs and its own NAT gateways, and told the
  # operator to delete them. Since --destroy is the documented path and monitoring keeps a node
  # resident by default, that made the primary teardown route unusable without the override.
  #
  # So ownership is answered three ways now: the id or a parent id inside the description is in the
  # state (covers NAT gateways, VPC endpoints, S3 Files / EFS mount targets), the description names
  # this cluster's control plane, or the ENI is attached to an instance carrying this cluster's
  # kubernetes.io/cluster tag. That last one is what covers nodes: Karpenter and the managed
  # nodegroup terminate them during destroy, so they are in transit, not blockers.
  local cluster instance_ids
  cluster="$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null || true)"
  instance_ids=""
  if [[ -n "$cluster" ]]; then
    instance_ids="$(aws ec2 describe-instances --region "$region" \
      --filters "Name=vpc-id,Values=$vpc" "Name=tag-key,Values=kubernetes.io/cluster/${cluster}" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' '\n' || true)"
  fi

  local enis sgs
  enis="$(aws ec2 describe-network-interfaces --region "$region" \
    --filters "Name=vpc-id,Values=$vpc" \
    --query 'NetworkInterfaces[].[NetworkInterfaceId,Attachment.InstanceId,Description]' --output text 2>/dev/null || true)"
  sgs="$(aws ec2 describe-security-groups --region "$region" \
    --filters "Name=vpc-id,Values=$vpc" \
    --query 'SecurityGroups[].[GroupId,GroupName]' --output text 2>/dev/null || true)"

  local found=0 id desc name attached
  # An ENI in a subnet this state owns blocks that subnet's delete, whatever created it. The
  # description is what identifies the owner: AWS writes "S3 Files mount target for fs-... (fsmt-...)",
  # "EFS mount target for fs-...", "ELB app/...", "VPC Endpoint Interface vpce-...",
  # "Interface for NAT Gateway nat-...". The ids inside it are checked against the state too, since
  # an ENI created on behalf of a managed resource has an id the state never sees.
  while IFS=$'\t' read -r id attached desc; do
    [[ -n "$id" ]] || continue
    printf '%s\n' "$state_ids" | grep -qxF "$id" && continue
    # Attached to one of this cluster's own nodes: in transit, not a blocker.
    if [[ -n "$attached" && "$attached" != "None" && -n "$instance_ids" ]]; then
      printf '%s\n' "$instance_ids" | grep -qxF "$attached" && continue
    fi
    # This cluster's control-plane ENIs. AWS names them after the cluster and owns the ids.
    [[ -n "$cluster" && "$desc" == "Amazon EKS ${cluster}" ]] && continue
    local claimed=0 tok
    for tok in $(printf '%s' "$desc" | tr -c 'a-zA-Z0-9-' ' '); do
      case "$tok" in
        fsmt-* | fsap-* | fs-* | vpce-* | eni-* | nat-* | i-*)
          printf '%s\n' "$state_ids" | grep -qxF "$tok" && { claimed=1; break; } ;;
      esac
    done
    [[ "$claimed" == "1" ]] && continue
    [[ "$found" == "0" ]] && echo "  Network interfaces this state does not own (they hold the subnets):" >&2
    found=1
    printf '    %s  %s\n' "$id" "${desc:-(no description)}" >&2
  done <<< "$enis"

  # A foreign security group only matters when its rules REFERENCE one of ours: that reference is
  # what turns our security group's delete into DependencyViolation. One that references nothing of
  # ours is harmless and is not reported, so the list stays short enough to act on.
  local sg_found=0 sg gname refs
  while IFS=$'\t' read -r sg gname; do
    [[ -n "$sg" ]] || continue
    [[ "$gname" == "default" ]] && continue
    printf '%s\n' "$state_ids" | grep -qxF "$sg" && continue
    refs="$(aws ec2 describe-security-group-rules --region "$region" \
      --filters "Name=group-id,Values=$sg" \
      --query 'SecurityGroupRules[].ReferencedGroupInfo.GroupId' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d;/^None$/d' || true)"
    local hits=""
    while read -r r; do
      [[ -n "$r" ]] || continue
      printf '%s\n' "$state_ids" | grep -qxF "$r" && hits="${hits} ${r}"
    done <<< "$refs"
    [[ -n "$hits" ]] || continue
    [[ "$sg_found" == "0" ]] && echo "  Security groups this state does not own, whose rules reference ours:" >&2
    sg_found=1
    found=1
    printf '    %s  %s  -> references%s\n' "$sg" "$gname" "$hits" >&2
  done <<< "$sgs"

  [[ "$found" == "0" ]] && return 0
  cat >&2 <<'HINT'
  These will make the LAST step of terraform destroy fail on DependencyViolation, after the
  cluster and nodes are already gone. Remove them first (their data is not in the VPC — an S3
  Files or EFS filesystem keeps its contents in S3 / the filesystem itself), then re-run:
    aws ec2 describe-network-interfaces --network-interface-ids <eni> --query 'NetworkInterfaces[].Description'
    # S3 Files: delete the mount targets, then the access points, then the filesystem
    aws cloudcontrol delete-resource --type-name AWS::S3Files::MountTarget --identifier <fsmt-...>
    aws cloudcontrol delete-resource --type-name AWS::S3Files::AccessPoint --identifier <fsap-...>
    # EFS: aws efs delete-mount-target --mount-target-id <fsmt-...>
    aws ec2 delete-security-group --group-id <sg>
  Or pass --ignore-vpc-dependents to run destroy anyway and deal with the failure when it comes.
HINT
  return 1
}

# Security groups EKS created for this cluster and left behind. Unlike the foreign objects above,
# these are unambiguously the cluster's own: EKS names them eks-cluster-sg-<cluster>-<id> and is
# supposed to delete them with the cluster, but one survived a real teardown and then blocked the
# VPC delete. Safe for this script to remove once the cluster is gone and nothing is attached —
# which is asserted, not assumed, before each delete.
sweep_eks_leftover_sgs() {
  local cluster="$1" region="$2" vpc="$3" swept=0 sg
  aws eks describe-cluster --name "$cluster" --region "$region" >/dev/null 2>&1 && return 0
  for sg in $(aws ec2 describe-security-groups --region "$region" \
    --filters "Name=vpc-id,Values=$vpc" "Name=group-name,Values=eks-cluster-sg-${cluster}-*" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d'); do
    local attached
    attached="$(aws ec2 describe-network-interfaces --region "$region" \
      --filters "Name=group-id,Values=$sg" --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 1)"
    if [[ "$attached" != "0" ]]; then
      echo "  Leaving $sg alone: $attached network interface(s) still attached." >&2
      continue
    fi
    if aws ec2 delete-security-group --group-id "$sg" --region "$region" >/dev/null 2>&1; then
      echo "  Removed the security group EKS left behind: $sg"
      swept=1
    fi
  done
  return $(( swept == 1 ? 0 : 1 ))
}

# ── Step 3: Optional terraform destroy ───────────────────────────────────────
if [[ "$RUN_DESTROY" == "true" ]]; then
  echo ""
  echo "Step 3 — Terraform destroy (removes EKS cluster and all AWS resources)"
  echo ""
  echo "!!! This will DELETE the EKS cluster, VPC, and all associated resources. !!!"
  echo "!!! This cannot be undone.                                                !!!"
  echo ""
  # Before an hour of destroy, not after: name anything in the VPC that this state does not own.
  if [[ -n "$VPC_ID" ]] && [[ -n "$REGION" ]]; then
    if ! vpc_dependents_report "$VPC_ID" "$REGION"; then
      if [[ "$IGNORE_VPC_DEPENDENTS" != "true" ]]; then
        echo "" >&2
        echo "Error: refusing to start destroy while the VPC holds objects listed above." >&2
        exit 1
      fi
      echo "  Proceeding anyway (--ignore-vpc-dependents)." >&2
    fi
  else
    echo "  Note: could not read vpc_id/region from the state, so the VPC was not checked for" >&2
    echo "        objects this state does not own. A destroy that fails at the end on" >&2
    echo "        DependencyViolation is what that looks like." >&2
  fi
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
    run_destroy() {
      if [[ "$AUTO_YES" == "true" ]]; then
        terraform destroy -auto-approve
      else
        terraform destroy
      fi
    }
    # One retry, and only after removing something. A destroy that reaches the VPC and fails there
    # has already deleted the cluster, which is what EKS was waiting on to clean up its own security
    # group; sweeping that and going again finishes the job in the same run instead of leaving a VPC,
    # its route table and two security groups behind for somebody to find later. If the sweep removed
    # nothing, the failure is something this script cannot fix, so it is reported as-is rather than
    # retried into the same wall.
    if ! run_destroy; then
      echo ""
      echo "  Destroy failed. Checking whether EKS left its own security group behind..." >&2
      if [[ -n "$VPC_ID" ]] && [[ -n "$REGION" ]] && sweep_eks_leftover_sgs "$CLUSTER_NAME" "$REGION" "$VPC_ID"; then
        echo "  Retrying destroy now that it is gone."
        run_destroy
      else
        echo "  Nothing left to sweep — the failure above is not one this script can clear." >&2
        if [[ -n "$VPC_ID" ]] && [[ -n "$REGION" ]]; then
          echo "  What is still in the VPC:" >&2
          vpc_dependents_report "$VPC_ID" "$REGION" || true
        fi
        exit 1
      fi
    fi
  else
    echo "  Skipped. Run manually: cd $INFRA_DIR && terraform destroy"
  fi
fi

echo ""
echo "=== Teardown complete ==="
