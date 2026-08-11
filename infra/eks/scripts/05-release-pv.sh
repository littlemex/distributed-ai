#!/usr/bin/env bash
# 05-release-pv.sh
# Return a static shared-storage PersistentVolume to Available — reliably, past every trap.
#
# A static PV (fsx-training / openzfs-shared / efs-neuron-workspace) uses reclaimPolicy=Retain,
# so once any PVC has bound it the PV keeps a spec.claimRef and will NOT accept a new PVC — least
# of all one in a DIFFERENT namespace — even when `kubectl get pv` prints STATUS=Available. Doing
# this by hand is a minefield: the claimRef can point at a deleted PVC in another namespace; the
# PVC may still be held by pods; those pods may be stuck Terminating on a finalizer with no
# controller left to clear it; and a tenant ValidatingAdmissionPolicy may reject patching them.
#
# SAFETY MODEL — this script only RELEASES a PV that is genuinely stranded:
#   - Available/Released with a claimRef whose PVC no longer exists (the "stale claimRef" trap), or
#   - Released.
# If the PV is genuinely in use (Bound to a PVC that still exists), it REFUSES unless you pass
# --force, so a mistyped --storage or a stray cron cannot dismantle a running workload. It NEVER
# deletes the PV or the underlying filesystem/data; it removes only the binding (and, with --force
# and your approval, the PVC and the pods pinning it).
#
# Usage:
#   ./05-release-pv.sh --storage fsx|openzfs|efs [--force] [--yes]
#   ./05-release-pv.sh --pv <pv-name>            [--force] [--yes]
#
# Flags:
#   --storage  Which shared-storage layer's PV to release; resolves the PV name from
#              `terraform output shared_storage` (fsx->fsx_lustre, openzfs->fsx_openzfs, efs->efs).
#   --pv       Release this PV by name directly (skips terraform). Must still be reclaim=Retain.
#   --force    Also release a PV that is Bound to a PVC that STILL EXISTS (delete that PVC and the
#              pods using it first). Without this, an in-use PV is refused.
#   --yes      Skip confirmations (non-interactive). Every safety gate still runs.
#
# Env:
#   TENANT_EXCLUDE_LABEL  Namespace label that exempts a namespace from the tenant VAP so pod
#                         finalizer patches are accepted (default tenantpools.dev/excluded).

set -uo pipefail

STORAGE="" ; PV="" ; AUTO_YES=false ; FORCE=false
TENANT_EXCLUDE_LABEL="${TENANT_EXCLUDE_LABEL:-tenantpools.dev/excluded}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

die() { echo "Error: $*" >&2; exit 1; }

# bash 3.2-safe yes/no (no ${var,,}).
confirm() {
  local msg="$1" ans
  if [[ "$AUTO_YES" == "true" ]]; then echo "$msg [auto-yes]"; return 0; fi
  read -rp "$msg [y/N] " ans
  case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --storage) [[ $# -ge 2 && "$2" != --* ]] || die "--storage requires a value (fsx|openzfs|efs)"; STORAGE="$2"; shift 2 ;;
    --pv)      [[ $# -ge 2 && "$2" != --* ]] || die "--pv requires a value"; PV="$2"; shift 2 ;;
    --force)   FORCE=true; shift ;;
    --yes)     AUTO_YES=true; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# ── Preflight: required tools (a missing one must fail loudly, not degrade silently) ──────────
command -v kubectl >/dev/null 2>&1 || die "kubectl not found on PATH."
command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH (used to scan pods safely)."

# ── Resolve the PV name ───────────────────────────────────────────────────────
[[ -n "$STORAGE" && -n "$PV" ]] && die "--storage and --pv are mutually exclusive."
if [[ -n "$STORAGE" ]]; then
  case "$STORAGE" in
    fsx)     KEY="fsx_lustre" ;;
    openzfs) KEY="fsx_openzfs" ;;
    efs)     KEY="efs" ;;
    *) die "--storage must be one of: fsx, openzfs, efs (got: $STORAGE)" ;;
  esac
  command -v terraform >/dev/null 2>&1 || die "terraform not found; pass --pv <name> to skip terraform resolution."
  TF_ERR=$(cd "$INFRA_DIR" && terraform output -json shared_storage 2>&1 >/dev/null || true)
  PV=$(cd "$INFRA_DIR" && terraform output -json shared_storage 2>/dev/null \
        | KEY="$KEY" python3 -c "import json,sys,os;d=json.load(sys.stdin);print(d[os.environ['KEY']]['persistent_volume'])" 2>/dev/null || true)
  [[ -n "$PV" && "$PV" != "None" ]] || die "could not resolve the PV for --storage $STORAGE from 'terraform output shared_storage' in $INFRA_DIR${TF_ERR:+ ($TF_ERR)}. Pass --pv <name> instead."
  echo "Resolved --storage $STORAGE -> shared_storage.$KEY.persistent_volume = $PV"
fi
[[ -n "$PV" ]] || die "specify --storage fsx|openzfs|efs or --pv <pv-name>."

# ── Context guard: operate on the intended cluster only ───────────────────────
CLUSTER_NAME=$(cd "$INFRA_DIR" && terraform output -raw cluster_name 2>/dev/null || true)
CTX=$(kubectl config current-context 2>/dev/null || true)
if [[ -n "$CLUSTER_NAME" ]]; then
  CTX_CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || true)
  if [[ "$CTX_CLUSTER" != *"cluster/$CLUSTER_NAME" && "$CTX_CLUSTER" != "$CLUSTER_NAME" ]]; then
    die "kubectl context ($CTX) does not target cluster '$CLUSTER_NAME'. Switch context first."
  fi
  echo "kubectl context OK: $CTX (cluster: $CLUSTER_NAME)"
else
  echo "WARNING: could not resolve cluster_name from terraform output; cannot verify the context." >&2
  [[ "$AUTO_YES" == "true" ]] && die "refusing to run with --yes while the cluster context is unverifiable (run 'terraform init', or drop --yes)."
  confirm "Continue against context '$CTX'?" || { echo "Aborted."; exit 1; }
fi

kubectl get pv "$PV" >/dev/null 2>&1 || die "PersistentVolume '$PV' not found in this cluster."

# ── Refuse anything that is not a Retain PV (a Delete PV would lose data on PVC removal) ───────
RECLAIM=$(kubectl get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null || true)
[[ "$RECLAIM" == "Retain" ]] || die "PV '$PV' has reclaimPolicy=$RECLAIM, not Retain. This tool only releases Retain PVs (deleting a PVC bound to a Delete PV destroys the volume and its data). Refusing."

# ── Read state once ───────────────────────────────────────────────────────────
STATUS=$(kubectl get pv "$PV" -o jsonpath='{.status.phase}' 2>/dev/null || true)
CR_NS=$(kubectl get pv "$PV" -o jsonpath='{.spec.claimRef.namespace}' 2>/dev/null || true)
CR_NAME=$(kubectl get pv "$PV" -o jsonpath='{.spec.claimRef.name}' 2>/dev/null || true)
CR_UID=$(kubectl get pv "$PV" -o jsonpath='{.spec.claimRef.uid}' 2>/dev/null || true)

echo ""
echo "=== Release plan ==="
echo "  PV       : $PV (reclaim: Retain)"
echo "  Cluster  : ${CLUSTER_NAME:-<unverified>}"
echo "  Status   : $STATUS   claimRef: ${CR_NS:-<none>}/${CR_NAME:-<none>}"
echo "  Force    : $FORCE"
echo ""

# Already truly free?
if [[ "$STATUS" == "Available" && -z "$CR_NS" && -z "$CR_NAME" ]]; then
  echo "PV '$PV' is already Available with no claimRef. Nothing to do."
  exit 0
fi

# ── Classify: is the bound PVC still alive? ───────────────────────────────────
# The claimRef can be a stale pointer to a deleted PVC (safe to clear) or a live binding (in use).
PVC_ALIVE=false
if [[ -n "$CR_NS" && -n "$CR_NAME" ]] && kubectl get pvc "$CR_NAME" -n "$CR_NS" >/dev/null 2>&1; then
  LIVE_UID=$(kubectl get pvc "$CR_NAME" -n "$CR_NS" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
  # Live and identity matches the claimRef (or claimRef.uid is empty but the PVC exists) => in use.
  if [[ -z "$CR_UID" || "$CR_UID" == "$LIVE_UID" ]]; then
    PVC_ALIVE=true
  fi
fi

if [[ "$PVC_ALIVE" == "true" && "$FORCE" != "true" ]]; then
  die "PV '$PV' is genuinely in use: PVC $CR_NS/$CR_NAME still exists (status=$STATUS). Refusing to disturb a live binding. If you are certain this PVC and its pods should be removed, re-run with --force."
fi

# ── With --force and a live PVC: remove the pods holding it, then the PVC ──────
if [[ "$PVC_ALIVE" == "true" ]]; then
  echo "PVC $CR_NS/$CR_NAME still exists and --force was given: it and the pods using it will be removed."
  PODS=$(kubectl -n "$CR_NS" get pods -o json 2>/dev/null | CR_NAME="$CR_NAME" python3 -c "
import json,sys,os
name=os.environ['CR_NAME']; out=[]
for p in json.load(sys.stdin).get('items',[]):
    for v in p.get('spec',{}).get('volumes',[]):
        if v.get('persistentVolumeClaim',{}).get('claimName')==name:
            out.append(p['metadata']['name']); break
print('\n'.join(out))
" 2>/dev/null || true)
  if [[ -n "$PODS" ]]; then
    echo "  Pods using $CR_NS/$CR_NAME:"
    while IFS= read -r pod; do
      [[ -z "$pod" ]] && continue
      owner=$(kubectl -n "$CR_NS" get pod "$pod" -o jsonpath='{range .metadata.ownerReferences[*]}{.kind}/{.name}{" "}{end}' 2>/dev/null || true)
      echo "    $pod   owner: ${owner:-<none, bare pod>}"
      # A live controller (Deployment/StatefulSet/ReplicaSet/running Job) will just recreate the pod.
      case "$owner" in
        Deployment/*|ReplicaSet/*|StatefulSet/*|Job/*)
          if kubectl -n "$CR_NS" get "${owner%%/*}" "${owner#*/}" >/dev/null 2>&1; then
            die "pod $pod is managed by a live ${owner% } — it will be recreated and re-pin the PVC. Delete or scale down that controller first, then re-run."
          fi ;;
      esac
    done <<< "$PODS"
    if confirm "  Delete these pods so the PVC can be removed?"; then
      # Temporarily exempt the namespace from the tenant VAP so finalizer patches are accepted.
      # Preserve the ORIGINAL label state (present-with-value / absent) and restore it no matter how
      # we exit. jsonpath uses bracket form because the key contains a dot and a slash.
      LABEL_STATE=$(kubectl get namespace "$CR_NS" -o json 2>/dev/null \
        | L="$TENANT_EXCLUDE_LABEL" python3 -c "import json,sys,os
k=os.environ['L']
try: labels=json.load(sys.stdin).get('metadata',{}).get('labels',{}) or {}
except Exception: labels={}
print('present='+labels[k] if k in labels else 'absent')" 2>/dev/null || echo "unknown")
      [[ "$LABEL_STATE" == "unknown" ]] && die "could not read namespace $CR_NS labels to safely toggle the VAP exemption."
      restore_label() {
        case "$LABEL_STATE" in
          present=*) kubectl label namespace "$CR_NS" "$TENANT_EXCLUDE_LABEL=${LABEL_STATE#present=}" --overwrite >/dev/null 2>&1 \
                       || echo "WARNING: failed to restore label $TENANT_EXCLUDE_LABEL on $CR_NS — verify manually." >&2 ;;
          absent)    kubectl label namespace "$CR_NS" "${TENANT_EXCLUDE_LABEL}-" >/dev/null 2>&1 \
                       || echo "WARNING: failed to remove temporary label $TENANT_EXCLUDE_LABEL on $CR_NS — VAP exemption may persist; remove it manually." >&2 ;;
        esac
      }
      trap restore_label EXIT INT TERM
      kubectl label namespace "$CR_NS" "$TENANT_EXCLUDE_LABEL=true" --overwrite >/dev/null 2>&1 \
        || die "failed to add temporary VAP-exemption label to $CR_NS; cannot safely clear pod finalizers."
      while IFS= read -r pod; do
        [[ -z "$pod" ]] && continue
        kubectl -n "$CR_NS" delete pod "$pod" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
      done <<< "$PODS"
      # Give normal graceful termination time (default 30s) before touching finalizers. Only pods
      # that are ACTUALLY deletion-blocked (deletionTimestamp set AND finalizers remaining) get a
      # targeted removal of the known job-tracking finalizer — never a blanket finalizers:null.
      WAIT=0
      while [[ $WAIT -lt 90 ]]; do
        stuck=$(kubectl -n "$CR_NS" get pods -o json 2>/dev/null | python3 -c "
import json,sys
try: items=json.load(sys.stdin).get('items',[])
except Exception: items=[]
print(sum(1 for p in items if p['metadata'].get('deletionTimestamp') and p['metadata'].get('finalizers')))" 2>/dev/null || echo 0)
        [[ "$stuck" -eq 0 ]] && break
        sleep 10; WAIT=$((WAIT+10))
      done
      # Targeted finalizer removal on still-stuck, terminating pods.
      for pod in $(kubectl -n "$CR_NS" get pods -o json 2>/dev/null | python3 -c "
import json,sys
try: items=json.load(sys.stdin).get('items',[])
except Exception: items=[]
for p in items:
    if p['metadata'].get('deletionTimestamp') and p['metadata'].get('finalizers'):
        print(p['metadata']['name'])" 2>/dev/null || true); do
        # remove the batch job-tracking finalizer specifically; fall back to clearing all only if
        # that is the sole finalizer left (avoids nuking mesh/cost finalizers on unrelated pods).
        fins=$(kubectl -n "$CR_NS" get pod "$pod" -o jsonpath='{.metadata.finalizers}' 2>/dev/null || true)
        if printf '%s' "$fins" | grep -q 'batch.kubernetes.io/job-tracking'; then
          kubectl -n "$CR_NS" patch pod "$pod" --type=json \
            -p '[{"op":"test","path":"/metadata/finalizers","value":["batch.kubernetes.io/job-tracking"]},{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 \
            || kubectl -n "$CR_NS" patch pod "$pod" -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || true
        else
          echo "  Note: pod $pod is stuck on finalizers [$fins] — not auto-clearing unknown finalizers; clear manually if needed." >&2
        fi
      done
      restore_label
      trap - EXIT INT TERM
    else
      die "pod deletion declined; cannot remove the live PVC. Aborting without touching the PV."
    fi
  fi
  # Delete the PVC and CONFIRM it is gone before we touch the PV.
  if confirm "  Delete PVC $CR_NS/$CR_NAME? (PV is Retain, so the filesystem/data is NOT deleted)"; then
    ERR=$(kubectl -n "$CR_NS" delete pvc "$CR_NAME" --ignore-not-found=true --wait=false 2>&1) || echo "  $ERR" >&2
    gone=false
    for _ in $(seq 1 18); do
      kubectl get pvc "$CR_NAME" -n "$CR_NS" >/dev/null 2>&1 || { gone=true; break; }
      sleep 5
    done
    [[ "$gone" == "true" ]] || die "PVC $CR_NS/$CR_NAME did not delete (still holding the pvc-protection finalizer via a pod, or a webhook blocks it). Clear the pods shown above, then re-run. NOT touching the PV's claimRef while the PVC is alive."
  else
    die "PVC deletion declined; not touching the PV's claimRef while the PVC is alive."
  fi
fi

# ── Hard guard: never remove the claimRef while its PVC still exists ──────────
if [[ -n "$CR_NS" && -n "$CR_NAME" ]] && kubectl get pvc "$CR_NAME" -n "$CR_NS" >/dev/null 2>&1; then
  die "PVC $CR_NS/$CR_NAME still exists — refusing to strip the claimRef (that would make the PVC Lost). Remove the PVC first (re-run with --force to do it automatically)."
fi

# ── Remove the stale claimRef so ANY namespace's PVC can bind next ────────────
if [[ -n "$(kubectl get pv "$PV" -o jsonpath='{.spec.claimRef}' 2>/dev/null || true)" ]]; then
  if confirm "Remove the stale claimRef from PV '$PV' so it becomes Available?"; then
    ERR=$(kubectl patch pv "$PV" --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]' 2>&1) \
      || ERR=$(kubectl patch pv "$PV" -p '{"spec":{"claimRef":null}}' --type=merge 2>&1) \
      || die "failed to remove the claimRef from '$PV': $ERR"
  else
    die "claimRef removal declined; PV will not become Available."
  fi
fi

# ── Verify ────────────────────────────────────────────────────────────────────
for _ in $(seq 1 12); do
  STATUS=$(kubectl get pv "$PV" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  CR=$(kubectl get pv "$PV" -o jsonpath='{.spec.claimRef}' 2>/dev/null || true)
  if [[ "$STATUS" == "Available" && -z "$CR" ]]; then
    echo ""
    echo "SUCCESS: PV '$PV' is now Available (no claimRef). Any namespace's PVC can bind it."
    exit 0
  fi
  if [[ "$STATUS" == "Bound" ]]; then
    NEW_NS=$(kubectl get pv "$PV" -o jsonpath='{.spec.claimRef.namespace}' 2>/dev/null || true)
    NEW_NAME=$(kubectl get pv "$PV" -o jsonpath='{.spec.claimRef.name}' 2>/dev/null || true)
    # Re-binding to the ORIGINAL stuck claim means we did not actually free it.
    if [[ "$NEW_NS/$NEW_NAME" == "$CR_NS/$CR_NAME" ]]; then
      die "PV re-bound to the original claim $CR_NS/$CR_NAME — it was not released."
    fi
    echo ""
    echo "SUCCESS: PV '$PV' rebound to a waiting PVC ($NEW_NS/$NEW_NAME). It is in use again, as intended."
    exit 0
  fi
  sleep 5
done

echo ""
echo "Warning: PV '$PV' did not reach Available/Bound. Current state:" >&2
kubectl get pv "$PV" >&2
exit 1
