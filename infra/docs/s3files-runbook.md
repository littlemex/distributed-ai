# S3 Files — teardown order & access-point recovery runbook

S3 Files spans **two Terraform states**: the file system + access point live in `infra/data-layer`;
the in-VPC mount target, the CSI `PersistentVolume`/`PersistentVolumeClaim`, and the mount IAM live
in `infra/eks` (they need the cluster VPC) and consume the data-layer's `s3files_volume_handle`
output. Terraform cannot order operations across separate states, so the ordering below is a
**manual invariant**, not something `depends_on` can enforce.

## Teardown order (must)

Destroy **`infra/eks` before `infra/data-layer`**.

- Correct: `terraform -chdir=infra/eks destroy` (removes the mount target + PV/PVC), then
  `terraform -chdir=infra/data-layer destroy` (removes the access point + file system).
- Wrong (data-layer first): the access point is deleted immediately — an **instant I/O outage** for
  any live consumer pod (analysis-mcp / remote-mcp) holding the mount — and then the file-system
  delete **fails** because the mount target still references it (EFS-backed: a file system with an
  active mount target cannot be deleted). This is fail-closed (the fs is not orphaned), but you are
  left in a half-torn state and must still go destroy `infra/eks` to proceed.

## Access-point recreation → consumers need PV/PVC recreation (not a re-apply)

Recreating the S3 Files stack (or any change that replaces the access point) mints a **new
`AccessPointId`**, so `s3files_volume_handle` changes (`s3files:<fs>::<ap>`). A PV's `volumeHandle`
is **immutable**: `kubectl apply` / `helm upgrade` on the chart will **fail** ("field is immutable"),
it does not silently reconcile. Recovery:

1. Scale down the consumer so nothing holds the PVC: `kubectl -n mcp scale deploy/<name> --replicas=0`
   (a bound PVC cannot be deleted while a pod mounts it).
2. Delete the old PVC and PV: `kubectl -n mcp delete pvc <name>-traces` then
   `kubectl delete pv <the-bound-pv>` (PVs are cluster-scoped).
3. Re-apply the chart with the new `s3files.volumeHandle` (from `terraform output s3files_volume_handle`);
   the shared `s3files-lib` template recreates the PV/PVC with the new handle.
4. Scale the consumer back up: `kubectl -n mcp scale deploy/<name> --replicas=1`.

## Single-AZ reminder

There is one mount target in one AZ (`s3files_mount_target_az` output); the NFS DNS resolves
per-AZ, so consumer pods are pinned to that AZ via the PV `nodeAffinity`. A pod scheduled in another
AZ hangs in `ContainerCreating`. Add more mount targets (one per AZ) for multi-AZ serving.
