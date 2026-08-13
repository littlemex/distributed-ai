# Accelerator Hardening Design

This design hardens Trainium/Neuron serving in three places without changing existing GPU behavior when the new knobs are left unset.

## 1. Compile host-RAM headroom

Problem: first-run Neuron graph compilation can fork enough host-side compiler work to OOM the kubelet before the accelerator dies.

Change:
- `accelerator_pools` now accepts optional per-pool `kubelet_system_reserved_memory` and `kubelet_eviction_hard_memory_available`.
- `karpenter-resources.tf` keeps the old shared accelerator `userData` heredoc as the default path and renders a per-pool override only when one of those fields is explicitly set.

Why this is GPU-neutral:
- Unset defaults reproduce today's render exactly: `systemReserved.memory = "2Gi"` and no `evictionHard` stanza.
- The existing GPU-only `gdrcopy` MIME branch still applies only to `device_plugin = "nvidia"`; the Neuron-specific headroom override is injected underneath that same per-pool branch pattern instead of changing the GPU default path.

How to verify:
- Render a GPU pool before/after with the new fields unset and confirm identical `EC2NodeClass.spec.userData`.
- Run `terraform plan` against an existing GPU tfvars file and confirm no diff for GPU `EC2NodeClass` / `NodePool`.

Rationale (defense in depth, two layers):
- Layer (a), above, is the host contract: `systemReserved`/`evictionHard` kernel-enforce Node
  Allocatable so the kubelet/containerd survive no matter what a Pod does. This is the last line of
  defense — the real failure in production was not "eviction too slow" but "the kubelet's survival
  was not cgroup-guaranteed", so raising the reservation is the root fix, not eviction tuning.
- Layer (b), the primary guard, lives in the serving chart: `neuronServingVllm` renders
  `resources.requests.memory == resources.limits.memory` (Guaranteed QoS for memory). This converts a
  runaway compile from "node dies tens of minutes later, non-deterministically, taking the kubelet
  with it" into "the Pod's own cgroup OOM-kills deterministically, with a Kubernetes event" — the
  compile pressure never reaches node-level memory pressure. Karpenter also sizes capacity from this
  request, so "scheduled but the host dies" cannot happen. Keep request and limit equal; do not offer
  an independent limit override, or this determinism breaks.
- Compile fork parallelism should be derived from that memory budget (peak-per-job into available
  request), not set as an independent knob that can drift out of sync and reintroduce the OOM. Today
  the app caps it via `VLLM_NEURON_PARALLEL_TRACE_WORKERS`; a chart-side derivation from the memory
  request is the clean follow-up.

## 2. Drain-stuck NotReady node reaper

Problem: when a node's kubelet is dead, Karpenter cannot drain it, so the deleting `NodeClaim` stays wedged on `karpenter.sh/termination` and a reserved capacity slot never frees.

Change:
- `accelerator_pools` now accepts optional `stuck_node_reaper_enabled` and `stuck_node_reaper_notready_threshold`.
- A new in-cluster CronJob (`accelerator-stuck-node-reaper.tf`) is created only when at least one pool enables it.
- The CronJob runs on the stable system tier, assumes its own Pod Identity role, lists `NodeClaims`, and only targets claims that:
  - belong to an enabled pool,
  - already have `metadata.deletionTimestamp`,
  - still carry `karpenter.sh/termination`,
  - and whose backing Node has stayed `Ready != True` in a kubelet-dead state past the threshold.
- The script terminates the EC2 instance first, waits until EC2 reports it gone, then removes only the Karpenter termination finalizer and deletes the dead Node object.

Why this is GPU-neutral:
- The reaper is off by default for every pool, so no GPU pool changes unless a specific GPU pool opts in.
- It is independent of the destroy-time drain gate in `karpenter.tf` and does not enable Karpenter NodeRepair.

How to verify:
- With all pools leaving `stuck_node_reaper_enabled = false`, `terraform plan` should show no new reaper resources.
- With one Neuron pool opting in, confirm the plan adds only the reaper IAM/RBAC/CronJob resources and does not modify GPU pool manifests.
- On-cluster, inspect the CronJob logs for the safety sequence: detect stuck deleting `NodeClaim` -> terminate EC2 -> wait for termination -> patch finalizer -> delete Node.

## 3. Neuron compile cache (shared, EFS-backed)

Requirement: NEFF compilation is expensive, and the compiled artifacts are worth persisting and
sharing across both serving (`neuronServingVllm`) and training (`neuronDdp`).

Why EFS dynamic access points, not a static OpenZFS PV:
- The module provisions a single OpenZFS static PV (`openzfs-shared`), and a static PV binds to
  exactly one PVC. A dedicated cache PVC bound to it would either sit `Pending` (if another claim
  already holds it) or lock every other workload out of it. OpenZFS is also single-AZ, so a cache
  bound there is unreachable from Neuron nodes that Karpenter places in other AZs.
- The `efs-shared` StorageClass (`provisioningMode: efs-ap`, from `efs.tf`) provisions a dedicated
  EFS access point per PVC. Multiple cache PVCs therefore coexist, and EFS mount targets in every
  private subnet make the cache reachable across AZs.

Change:
- A shared top-level `neuronCache` values block: `enabled`, `create`, `pvcName`,
  `storageClassName` (default `efs-shared`), `size`, `mountPath`.
- `neuron-cache-pvc.yaml` renders a dynamically provisioned PVC (no `volumeName`) when
  `create=true`, and fails fast if `pvcName` or `storageClassName` is empty.
- `neuronServingVllm` and `neuronDdp` mount the cache when `neuronCache.enabled=true`: serving sets
  `NEURON_COMPILED_ARTIFACTS` (its load path), training sets `NEURON_COMPILE_CACHE_URL` (the
  torch-neuronx persistent cache; a dedicated env avoids clobbering user `NEURON_CC_FLAGS`). Both
  default to unset, so with `enabled=false` the render is unchanged. They share one filesystem but
  separate subtrees: serving is namespaced per model + TP (`.../vllm/<model>/tp<N>`, since
  `NEURON_COMPILED_ARTIFACTS` is a per-model directory, not content-addressed), training uses
  `.../neuron-cc` (content-addressed by hash, so it is collision-safe).

Lifecycle: the PVC carries `helm.sh/resource-policy: keep` and the StorageClass reclaim policy is
`Retain`. Deleting the PVC does not delete the EFS data, but a re-created PVC provisions a NEW
access point and starts empty, so the cache is preserved by keeping the PVC alive rather than by
re-binding a released PV.

Premise: `var.efs_enabled = true` (default `false`); enabling it is an additive `terraform apply`
(EFS filesystem, mount targets, StorageClass).

How to verify:
- `helm template` with defaults emits no cache PVC.
- `helm template --set neuronCache.create=true --set neuronCache.pvcName=neuron-cache` emits exactly
  one PVC with `storageClassName: efs-shared` and no `volumeName`.
- `helm template --set neuronServingVllm.enabled=true --set neuronDdp.enabled=true --set
  neuronCache.enabled=true --set neuronCache.pvcName=neuron-cache` mounts the cache PVC in both
  workloads at `neuronCache.mountPath`.
- `gpu-serving-vllm.yaml` is unchanged.
