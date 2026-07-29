# Node role separation for this EKS cluster (design + migration plan)

Status: the Terraform-side *receivers* are in place in this module (the `node-role`
labels, `system_node_volume_size`, the raised `cpu_node_volume_size` default, and the
sanctuary taint left commented out on purpose). The runtime migration — moving the
operators to the `cpu` pool, then uncommenting the taint, then rolling the system disk —
has NOT been performed on any live cluster yet; follow the step order below.

Origin: validating `awsome-distributed-ai/3.test_cases/pytorch/slime` (KubeRay + Ray +
SGLang + Megatron GRPO) on this module's cluster (GPU tier = p5en.48xlarge x2, H200 x16,
EFA 16, SLIME image ~14 GB). The GRPO 1-rollout smoke completed end to end, but the Ray
head hit an infrastructure blocker that exposed a broader node-role-separation gap. This
doc is the design we should converge to, plus a non-destructive migration order. Reviewed
with a principal-level pass.

Note on `NodeProvisioningMode: Continuous`: that is a SageMaker HyperPod instance-group
setting for HyperPod-native (esp. Spot) node replacement. This cluster is plain EKS +
Karpenter — node replenishment is Karpenter's job — so `Continuous` does not apply here.
The SLIME README mentions it only for adding a `reward-spot-c5` HyperPod instance group.

## What happened (the trigger)

The RayCluster manifest schedules the Ray head onto a non-GPU node via a *negative*
nodeAffinity (`nvidia.com/gpu.present NotIn true`). The head pulls the ~14 GB SLIME image
but runs only the Ray GCS + dashboard (no GPU). It landed on a **system managed-nodegroup**
`m5.xlarge` and was evicted mid image-pull:

```
The node was low on resource: ephemeral-storage.
Threshold quantity: 5360737974, available: 5121488Ki   (~5 GB free)
```

Allocatable ephemeral-storage there is ~18 GB; after system pods/images ~5 GB remained —
too little to unpack a 14 GB image. A retry on an `m5a.2xlarge` (47 GB) was evicted again
after unpack crossed the threshold. Temporary unblock for the smoke (manifest edit, not
committed): replaced the head's GPU-avoidance affinity with a toleration for the GPU taint
so the head ran on a p5en node (huge instance store). It came up immediately and the run
completed.

## Root cause: two defects + a missing role boundary

1. **Pods declare no `ephemeral-storage` request** → the scheduler ignores disk headroom and
   places the head on a ~5 GB-free node. Primary defect; no node-size change fixes it.
2. **The head's node selection is a *negative* condition** (`gpu.present NotIn true`) → it
   names no target and matches *both* CPU receivers. It landed on the system nodegroup.
3. **The system nodegroup is not a sanctuary**: no taint, so it became a "mixed-use
   building" hosting not just kube-system but also gpu-operator / mpi-operator /
   kuberay-operator and (accidentally) the Ray head.

## Measured facts (this cluster, at the time of the incident)

These are the values that were live when the eviction happened; this commit then changes
the two defaults called out below.

- `eks.tf` `eks_managed_node_groups.system` (m5.xlarge x2): **no `disk_size`** (~20 GB
  default) and **no taint** (only label `karpenter.sh/controller=true`). (This commit adds
  `disk_size = var.system_node_volume_size` (50) and the `node-role=system` label; the taint
  stays commented out.)
- Karpenter `cpu` NodePool / EC2NodeClass: **no taint**, root EBS = `cpu_node_volume_size`
  (**default was `50Gi` at the time; this commit raises the default to `150Gi`**); one
  `m5a.2xlarge` currently running.
- On the two system nodes today:
  - Tolerate all taints (safe to sanctuary): kube-system (CoreDNS, aws-node, kube-proxy,
    EBS/EFS/FSx CSI, pod-identity), `karpenter` controller.
  - Do NOT tolerate `CriticalAddonsOnly` (would be evicted by a naive taint):
    `gpu-operator` (+ NFD master/worker/gc), `mpi-operator`, `kuberay-operator`.
  → So a bare `CriticalAddonsOnly` taint on the system nodegroup is **destructive** as-is:
    it would strand those three operators (they have nowhere they currently target).

## Target design: three tiers

The single decision rule: **"if Karpenter were entirely down, would this need to already be
running for the cluster to recover?"** Only that qualifies for the system tier. "Lightweight
and long-lived" is NOT the bar — depending-on-Karpenter-being-up is.

| Tier | Backing | Hosts | Taint |
|------|---------|-------|-------|
| system | EKS managed nodegroup (fixed m5.xlarge x2) | kube-system + Karpenter controller **only** | `CriticalAddonsOnly=true:NoSchedule` |
| general CPU | Karpenter `cpu` NodePool | the 3 operators + other CPU workloads | none |
| heavy resident | `cpu` pool + protective attrs (or a dedicated pool later) | Ray head | (dedicated taint if/when split out) |

Rationale:

- **Operators belong on the `cpu` pool, not system.** gpu-operator / mpi-operator /
  kuberay-operator are stateless Deployments; if Karpenter is up they reschedule freely and
  a few minutes of controller Pending breaks nothing already-running (existing RayCluster /
  MPIJob keep running). They fail the system-tier rule, so they move to the `cpu` pool.
  Keeping them on system via tolerations is rejected: it perpetuates the "system is a
  building you can't taint" state that caused this, and forces operator resource envelopes
  into a fixed 2-node/20 GB tier. System's value is being fixed and predictable.
- **Operators vs Ray head are different despite both being resident singletons.** Operators
  = few-hundred-MB image, stateless, free to reschedule → plain on `cpu` pool. Ray head =
  14 GB image, holds Ray GCS state, reschedule == cluster outage → same pool but with
  protective attributes (below).
- **A dedicated `ray-control` NodePool is overkill now** — the protective attributes cover
  the failure modes. Justified later if multiple Ray heads run with real availability
  requirements; splitting it is one extra NodePool resource, cheap to add then.

## Fixes

### Terraform (infra/eks) — the *shape* of the receivers

1. **Role labels** on both receivers (non-destructive, in-place). The Karpenter pools
   already carry a `node-role` label (cpu pool = `cpu`, accelerator pools = their name);
   the only gap is the system MNG, so add `node-role = "system"` there. Reusing this
   existing key (rather than `karpenter.sh/nodepool`) keeps one selector vocabulary and is
   robust to pool renames.
2. **`CriticalAddonsOnly=true:NoSchedule` taint** on the system MNG — **only after** the
   operators have been moved (see migration). MNG taint update is an in-place EKS API change
   (no node replacement); `NoSchedule` does not evict existing pods.
   ```hcl
   # eks.tf, eks_managed_node_groups.system
   taints = { critical = { key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" } }
   ```
   (Verify Karpenter's Helm tolerations still cover this — measured today: it tolerates.)
3. **`cpu_node_volume_size` default 50Gi → 150Gi** (`variables.tf`). gp3 150 GiB ≈
   $12/node/mo — noise vs a p5en x2 cluster — and "unsafe default + doc warning"
   demonstrably failed to prevent this. Keep the override knob for cost-sensitive clusters.
   Optional non-breaking plan-time `check` that warns if `< 150Gi`.
4. **system MNG `disk_size = 50`** (`eks.tf`) — defense in depth. This one triggers a
   rolling node replacement, so do it LAST (see migration), after CoreDNS 2-replica + PDB
   are confirmed.

### Helm values (git-managed, NOT kubectl patch) — *where operators run*

`nodeSelector: { node-role: cpu }` on gpu-operator / mpi-operator / kuberay-operator.
If these are installed by hand today, put their `values.yaml` in the repo and drive them via
`helm_release` / helmfile / Argo so the selector is not lost on the next `helm upgrade`.

### RayCluster manifest (workload repo) — *where the head runs*

- `ephemeral-storage` request (~30 GiB: image + logs) — direct fix for the eviction.
- `nodeSelector: { node-role: cpu }` (positive; drop the negative affinity).
- `karpenter.sh/do-not-disrupt: "true"` annotation — the head holds the GCS singleton; do
  not let consolidation reap it mid-run.
- Also parameterize `vpc.amazonaws.com/efa` (a machine property: p5.48xlarge = 32,
  p5en.48xlarge = 16 with ~15 schedulable — the device plugin reserves one) via an
  `EFA_PER_NODE` env in the manifest, plus the image ref, so the same manifest runs on
  both machine types. It must equal the EFA interface count the EC2NodeClass renders for
  that instance type. (This is a machine difference, not an infra defect.)

## Non-destructive migration order

Principle: **provision the receiver → move the pods → taint LAST.** Any order that taints
first will strand pods.

1. **[prep]** Add `node-role = "system"` to the system MNG (the Karpenter pools already
   carry `node-role`). Terraform apply; label-only, non-destructive.
2. **[move]** Add `nodeSelector: {node-role: cpu}` to the 3 operators' Helm values and
   upgrade. Pods move to the `cpu` pool (Karpenter adds a node if needed). Do the
   **mpi-operator move while no MPIJob is running.** gpu-operator controller restart does not
   disturb the driver/device-plugin DaemonSets on running GPU nodes.
3. **[verify]** Confirm the two system nodes now host only kube-system + karpenter.
4. **[seal]** Add the `CriticalAddonsOnly` taint to the system MNG (Terraform apply).
   In-place, no node replacement, no evictions — safe because steps 2–3 already emptied it.
5. **[ray head]** Update the RayCluster manifest: positive nodeSelector, `ephemeral-storage`
   request, `do-not-disrupt`. Raise `cpu_node_volume_size` if 50Gi is short (EC2NodeClass
   change applies to new nodes; existing nodes roll as drift — non-destructive).
6. **[last]** Set system MNG `disk_size = 50` — rolling node replacement; do it in a calm
   window with `max_unavailable=1` and CoreDNS 2-replica + PDB confirmed.
7. **[guardrail, low priority]** Consider Kyverno/Gatekeeper to warn on workload pods that
   don't select a role label, to stop negative-affinity regressions.

## Extra pitfalls (beyond the two measured defects)

- **Taint does not evict existing pods (NoSchedule)** — so a taint applied *before* moving
  operators looks fine at apply time, then Pending-bombs on the next rollout days later.
  This is exactly why the migration moves operators first.
- **DaemonSet awareness**: NFD workers are DaemonSets and will stop landing on tainted system
  nodes (desired). Check gpu-operator's DaemonSet tolerations vs both GPU taint and
  CriticalAddonsOnly before tainting.
- **CoreDNS**: EKS-addon CoreDNS tolerates CriticalAddonsOnly by default; re-check if the
  addon config was customized.

## Code-ownership split

| Item | Owned by | Why |
|------|----------|-----|
| MNG taint / label / disk_size | **Terraform (infra/eks)** | receiver contract; must reproduce on rebuild |
| `cpu` NodePool / EC2NodeClass label + volume | **Terraform** | same |
| `ray-control` pool (if split later) | **Terraform** | same |
| operator nodeSelector / tolerations | **Helm values in git** | "where it runs" is a workload declaration; kubectl patch is lost on upgrade |
| Ray head selector / request / annotation | **RayCluster manifest (workload repo)** | per-experiment, but bake into the base manifest and stop drift in review |

Principle: **receiver shape (taint/label/size) = Terraform; placement declaration
(selector/toleration/request) = wherever that workload is defined.** Managing both in one
place turns Terraform into a Helm-values dump that rots.

## Priority

| Action | Priority |
|--------|----------|
| Move the 3 operators to the `cpu` pool (migration steps 1–3) | high (first) |
| Seal system with the taint (step 4) | high (right after) |
| Ray head request / selector / do-not-disrupt (step 5) | high — direct fix for this incident |
| system `disk_size = 50` (step 6) | medium — pressure drops once sanctuaried |
| `cpu_node_volume_size` default 150Gi (+ check) | medium |
| Dedicated `ray-control` NodePool | low — until Ray usage grows |
| Policy-engine negative-affinity detection | low |
