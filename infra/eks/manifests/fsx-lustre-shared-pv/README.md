# fsx-lustre-shared-pv — mount one FSx for Lustre filesystem from many namespaces

Templates for mounting a single, existing Amazon FSx for Lustre filesystem from more than one
namespace. FSx for Lustre cannot be split per PersistentVolumeClaim (its dynamic provisioning
creates a whole new filesystem), so cross-namespace use is done with additional static
PersistentVolumes that point at the same filesystem. Every namespace sees the same filesystem root:
this is shared-filesystem access, not isolation, and any per-tenant directory convention is
application-managed — these templates do not enforce it.

## When to use

- Several namespaces need read/write access to the same dataset or scratch area on one FSx for
  Lustre filesystem.
- You do **not** need tenant isolation. For per-tenant isolation on shared storage, use the
  [`openzfs-multitenant`](../../charts/openzfs-multitenant) chart (FSx for OpenZFS child volumes),
  and for performance isolation give each tenant its own filesystem.

## How it works

A static PersistentVolume binds to exactly one PersistentVolumeClaim. To let another namespace
mount the same filesystem, create another static PV with the same mount attributes but a unique
`volumeHandle`, and pre-reserve it with `claimRef`:

- **`volumeHandle` is unique per PV.** The CSI driver mounts by `dnsname`/`mountname` in
  `volumeAttributes`, not by `volumeHandle`; kubelet only uses `volumeHandle` to identify the
  volume. A unique value (the base handle plus the tenant suffix) avoids mount-tracking collisions.
  This repository uses the suffix-handle form only with `reclaimPolicy: Retain`, so the driver
  never treats the handle as a deletable FSx filesystem id.
- **`claimRef` pre-reserves the PV.** An unbound static PV can be bound by an unintended namespace,
  which on a shared filesystem exposes the data to the wrong namespace. `claimRef` binds the PV to
  one namespace and PVC name up front.

`mountOptions` (`flock`) and the access mode (`ReadWriteMany`) are fixed in the templates; adjust
the templates if the source PV uses different values.

## Usage

Render with `envsubst`, naming the variables explicitly. Copy the mount attributes from the
existing FSx for Lustre PV (created by `infra/eks` when `fsx_enabled = true`), then set the tenant
variables. Run from the repository root:

```bash
SRC_PV=$(terraform -chdir=infra/eks output -json shared_storage | jq -r '.fsx_lustre.persistent_volume')
export DNS=$(kubectl get pv "$SRC_PV" -o jsonpath='{.spec.csi.volumeAttributes.dnsname}')
export MOUNT=$(kubectl get pv "$SRC_PV" -o jsonpath='{.spec.csi.volumeAttributes.mountname}')
export HANDLE=$(kubectl get pv "$SRC_PV" -o jsonpath='{.spec.csi.volumeHandle}')
export CAP=$(kubectl get pv "$SRC_PV" -o jsonpath='{.spec.capacity.storage}')
: "${DNS:?}" "${MOUNT:?}" "${HANDLE:?}" "${CAP:?}"

export TENANT=team-b PV_NAME=fsx-shared-team-b CLAIM=fsx-claim
kubectl create namespace "$TENANT" --dry-run=client -o yaml | kubectl apply -f -

VARS='$TENANT $PV_NAME $CLAIM $DNS $MOUNT $HANDLE $CAP'
envsubst "$VARS" < infra/eks/manifests/fsx-lustre-shared-pv/pv.yaml.tmpl  | kubectl apply -f -
envsubst "$VARS" < infra/eks/manifests/fsx-lustre-shared-pv/pvc.yaml.tmpl | kubectl apply -f -
kubectl wait --for=jsonpath='{.status.phase}'=Bound "pvc/$CLAIM" -n "$TENANT" --timeout=60s
```

| Variable | Meaning |
|---|---|
| `TENANT` | Namespace that mounts the shared filesystem |
| `PV_NAME` | Unique PersistentVolume name |
| `CLAIM` | PVC name in `TENANT` that binds the PV |
| `DNS` / `MOUNT` / `HANDLE` / `CAP` | Mount attributes copied from the existing FSx for Lustre PV |

`envsubst "$VARS"` substitutes only the named variables, so any other `$…` text in a future
template revision is left intact. The PVC template carries its own `metadata.namespace` and the PV
is cluster-scoped, so neither `apply` needs `-n`.

## Cleanup

Deleting the PVC, PV, and namespace does not delete data on the shared filesystem; remove any files
the namespace wrote explicitly if offboarding.

```bash
kubectl delete pvc "$CLAIM" -n "$TENANT" --ignore-not-found
kubectl delete pv "$PV_NAME" --ignore-not-found
kubectl delete namespace "$TENANT" --ignore-not-found
```
