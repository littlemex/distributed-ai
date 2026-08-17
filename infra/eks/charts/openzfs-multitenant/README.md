# openzfs-multitenant — per-tenant FSx for OpenZFS volumes

Provisions one Amazon FSx for OpenZFS child volume per tenant, under an existing FSx for OpenZFS
filesystem, using dynamic provisioning. Each tenant namespace gets its own PersistentVolume backed
by a separate child volume with its own capacity quota, so a file written through one tenant's
claim is not visible through another's. Add or remove a tenant by editing the `tenants` list; no
template change.

This provides per-claim storage separation for cooperative tenants. It is not, by itself, a
security boundary: it holds only alongside RBAC/admission policy that stops tenants from creating
arbitrary PVCs against this StorageClass and an NFS export narrowed to the node subnet (see
[Isolation scope](#isolation-scope)). For a true trust boundary (separate customer, KMS key, or
billing), use a separate filesystem or account.

## Prerequisites

- An existing FSx for OpenZFS filesystem.
- The FSx for OpenZFS CSI driver, installed by `infra/eks` when OpenZFS support is enabled.
- Dynamic-provisioning IAM on the CSI controller role. It is off by default because it adds
  create/delete permissions; enable it before installing:

  ```bash
  terraform -chdir=infra/eks apply -var openzfs_dynamic_provisioning_enabled=true
  ```

## Values

| Key | Default | Description |
|---|---|---|
| `parentVolumeId` | `""` | Root volume of the existing filesystem to carve child volumes under. Get it from `terraform -chdir=infra/eks output -json shared_storage \| jq -r '.fsx_openzfs.root_volume_id'`. |
| `storageCapacityQuotaGiB` | `10` | Capacity quota (GiB) applied to the StorageClass, so every child volume it provisions carries this quota. This is chart-wide; per-tenant differing quotas are out of scope (a single StorageClass). |
| `tenants` | `[]` | Namespaces that each receive one PVC. Removing a namespace and upgrading deletes its PVC and, with `reclaimPolicy: Delete`, its child volume and data. |
| `pvcName` | `data` | Name of the per-tenant PVC created in each namespace. |
| `nfsExportClients` | `"*"` | NFS export client filter. `*` is convenient for a demo; restrict to the node subnet in production. |
| `storageClassName` | `openzfs-sc` | Name of the generated StorageClass. |

## CSI driver constraints

- **Quota lives on the StorageClass; the PVC request is fixed at `1Gi`.** With `ResourceType:
  volume`, the FSx for OpenZFS CSI driver (as of v1.2.0) rejects any PVC request other than `1Gi`
  (`InvalidArgument: resourceType Volume expects storage capacity to be 1Gi`). The real quota is
  `StorageCapacityQuotaGiB` on the StorageClass, not the PVC request.
- **`ParentVolumeId` is JSON-quoted (`'"..."'`).** The driver parses that parameter as a JSON
  string, so the inner quotes are required.
- The StorageClass sets `volumeBindingMode: Immediate`, so a PVC provisions its child volume as
  soon as it is created; `kubectl wait --for=...=Bound` succeeds before any workload runs.

## Isolation scope

Per-tenant child volumes give real separation only alongside two controls:

- **RBAC/admission policy** that prevents tenants from creating arbitrary PVCs against this
  StorageClass or editing the chart-managed claims. Dynamic provisioning fires on PVC creation, so
  a tenant able to create its own PVC against the StorageClass could provision additional child
  volumes; the claims are owned by cluster admins.
- **A narrowed NFS export.** Set `nfsExportClients` to the node subnet. The export uses `rw`
  without `crossmnt`, so a Pod mounting the parent volume cannot traverse into a child volume.

A namespace by itself is not a security boundary.

## Install

The chart's resources are a cluster-scoped StorageClass plus one PVC per tenant namespace, so the
release namespace is arbitrary.

```bash
for ns in tenant-a tenant-b; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

cat > my-values.yaml <<EOF
parentVolumeId: $(terraform -chdir=infra/eks output -json shared_storage | jq -r '.fsx_openzfs.root_volume_id')
storageCapacityQuotaGiB: 10
tenants: [tenant-a, tenant-b]
EOF

helm upgrade --install openzfs-multitenant infra/eks/charts/openzfs-multitenant -f my-values.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/data -n tenant-a --timeout=180s
```

Pass `tenants` in a values file rather than `--set tenants[0]=...`: index-addressed `--set` is
brittle when tenants are added or removed and collides with shell globbing unless quoted.

## Uninstall

`reclaimPolicy: Delete` plus `OptionsOnDeletion: ["DELETE_CHILD_VOLUMES_AND_SNAPSHOTS"]` mean
deleting a tenant's PVC (by removing it from `tenants` and upgrading, or by deleting its namespace)
deletes its child volume and data. To tear the whole thing down, delete the tenant namespaces
first so the child volumes are removed, then uninstall the release:

```bash
kubectl delete namespace tenant-a tenant-b
# wait until no child volumes remain under the parent filesystem, then:
helm uninstall openzfs-multitenant
```

Deletion of child volumes is asynchronous; confirm they are gone before turning the
dynamic-provisioning IAM back off, otherwise `DeleteVolume` fails with `AccessDenied` and the
volumes keep billing.

```bash
terraform -chdir=infra/eks apply -var openzfs_dynamic_provisioning_enabled=false
```
