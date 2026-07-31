# ADR 0001: Capacity, Instance-Type, and AZ Mixing in `accelerator_pools`

**Status**: Accepted
**Date**: 2026-07-31
**Context scope**: `variable "accelerator_pools"` in `variables.tf`, its rendering in
`karpenter-resources.tf` / `locals.tf` / `az.tf` / `capacity-block.tf`, and the workshop
chapters that teach it.

## Context

The existing schema modelled one pool as `1 pool = 1 capacity_type = 1 EFA topology = 1 AZ`.
`capacity_type` was a single string (`"reserved" | "on-demand" | "spot"`), `cb_reservation_id`
was a single id, and `zone` resolved to one AZ. This was believed to be a Karpenter
constraint. It is not.

We need a durable base that supports, as first-class capabilities (not bolted-on exceptions):

1. Mixing Capacity Block (reserved) + on-demand + spot in one cluster.
2. Mixing multiple GPU instance types (g5 / g6 / g6e, and EFA vs non-EFA).
3. Placing different workloads on different types (`g5.xlarge` → light inference,
   `g5.16xlarge` → training).
4. Tight, EFA-adjacent multi-node collectives (p5en with RDMA).
5. Loosely-coupled, single-AZ TCP workloads (g5/g6 running P/D disaggregation, using shared
   storage).
6. Loosely-coupled, multi-AZ workloads (inference fleets spread across AZs for availability;
   no shared storage, no Capacity Block, so no reason to pin to one AZ).

Two distinct *intents* were being conflated and must both be supported:

- **Intent F (fallback / meet the node count)**: "I want N nodes; take reserved first, fall
  back to spot, then on-demand to fill the count." Mixing is a *result* of availability.
- **Intent M (deliberate simultaneous coexistence)**: "run reserved baseline + spot burst
  concurrently by design." Mixing is the *intent*.

## Verified Karpenter facts (v1.13.x, provider-aws v1.13.0; source-verified)

These facts drove the decision. Citations live in the design notes referenced at the bottom.

- A single NodePool may list `karpenter.sh/capacity-type: ["reserved","on-demand","spot"]`.
  Karpenter natively prioritises **reserved → spot → on-demand** and falls back when a higher
  type is unavailable. **No multiple-NodePool + weight construct is needed for Intent F.**
- Karpenter models reserved capacity as **price = 0 (free)**. Consolidation therefore tries to
  fold spot/on-demand pods onto reserved nodes. **Consequence: Intent M cannot be guaranteed by
  pool definition alone** — consolidation would collapse the coexistence.
- `karpenter.sh/capacity-type` is a well-known label usable in a **pod** nodeSelector. Pinning a
  pod to `spot` (or to `karpenter.k8s.aws/capacity-reservation-id`) makes that pod
  unschedulable onto the other type, which is the only mechanism that *guarantees* coexistence.
- `capacityReservationSelectorTerms` accepts **multiple reservations** by id list or by tag map
  (max 20 keys). Open matching is **not** auto-discovered; every reservation used must be listed.
- An EC2NodeClass has **one** `networkInterfaces` layout. `compatibility.go` silently drops
  instance types whose EFA card count is incompatible. **Full-EFA mixing of differing EFA
  topologies in one pool is impossible**; official guidance is to split them into separate
  NodePool/EC2NodeClass pairs. Non-EFA types mix freely.
- A NodePool has an upper bound (`limits`) but **no floor** ("always N nodes"). `minValues`
  bounds requirement-key *diversity*, not node count. A static floor requires a Managed Node
  Group (outside Karpenter) or placeholder pods.
- The `ReservedCapacity` feature gate is **Beta** (default true in v1.13). Pin the Karpenter
  version; re-check the gate on upgrade.

## Decision

### D1 — Mix by native capacity-type list, not by weight

Add `capacity_types = list(string)` (subset of `reserved|on-demand|spot`). Render it directly
into NodePool requirements and let Karpenter's native priority/fallback handle Intent F. Keep
the legacy `capacity_type` (single) mapped to `[capacity_type]` for backward compatibility;
specifying both is an error.

### D2 — Intent F vs Intent M is a *pod* distinction, not a schema field

**Reject a tfvars `intent` field.** The pool definition for F and M is identical
(`capacity_types` with several values). The difference is whether pods pin their capacity-type:

- **No pin → Intent F** (Karpenter picks by priority, falls back to meet the count).
- **Pin `karpenter.sh/capacity-type` (or `…/capacity-reservation-id`) → Intent M** (each pod
  sticks to its type; consolidation cannot fold them together).

A schema `intent` field has no enforcement power over consolidation (only pod pinning does), so
it would be a decorative flag that produces "I wrote intent=M but they still merged" confusion.
The tight/loose and F/M concepts are taught in the book as **pod-manifest patterns**, not
fields. Rule of thumb: **tfvars declares what is *available*; the pod declares what is *used*.**

### D3 — Multiple reservations by id and/or tag

Add `capacity_reservations = object({ ids = list(string), tags = map(string) })`. Render one
selector term per id plus one tag term (OR-combined), only when the pool includes `reserved`.
Keep legacy `cb_reservation_id` mapped to `ids = [cb_reservation_id]`. A pool that lists
`reserved` must set `capacity_reservations` (open matching is unsupported); a non-reserved pool
must not set it.

### D4 — AZ is a first-class axis; multi-AZ ships in the first version

Add `zones = list(string)`. One element = single AZ; several = spread across the listed AZs;
`["*"]` = all cluster AZs. The single `zones` field expresses both single- and multi-AZ; do not
add a separate `zone` singular.

**Default `zones = [azs[0]]` always** (the AZ shared by FSx Lustre / FSx OpenZFS; EFS is off).
Multi-AZ is explicit opt-in. Fallback (Intent F) does **not** imply AZ spread — they are
orthogonal axes. A pool that shares single-AZ storage but wants capacity fallback keeps the
default and is correct with no override.

### D5 — Keep EFA numeric; split differing EFA topologies

Keep `efa_interface_count` (`-1` derive / `0` disable / positive explicit) and `efa_multi_card`
(bool). **Reject** the string `"auto"|"off"|"max"` form — numeric preserves the "explicitly use
8 of p5's 32 cards" capability and teaches EFA as a physical, counted resource. Extend the
`efa_capability` table with small GPUs as `{cards=0, multi_card=false}` so non-EFA pools need no
`efa_interface_count = 0` boilerplate. Keep the same-topology precondition (Guards 1–4): a pool
mixing differing EFA topologies fails at plan time with a "split the pool" message. EFA-enabled
pools are forced to a single AZ.

### D6 — Disruption as a two-layer preset

Add `disruption = "protect" | "reclaim"` (preset). Keep `consolidate_after` and
`disruption_budget_nodes` as override fields. Precedence: **raw field (non-null) > `disruption`
preset > `interruptible` (deprecated) > derived default**. Derived default:
`efa_interface_count > 0 OR capacity_reservations non-empty → protect`, else `reclaim`.
`protect` = `WhenEmpty` + `consolidateAfter "Never"` + `budget "0"`; `reclaim` =
`WhenEmptyOrUnderutilized` + `"30s"` + `"10%"`. Deprecate the `interruptible` bool
(`true→reclaim`, `false→protect`); specifying it alongside `disruption` is an error.

Running jobs on a `reclaim` pool are protected per-pod with `karpenter.sh/do-not-disrupt`;
budget is a NodePool-level rate limit and cannot select per-node, so job protection lives on the
pod. Reserved nodes are not consolidated regardless (price=0), so budget need not defend them.

### D7 — "Keep N nodes running" is a pod responsibility

tfvars supplies the candidate space (types × capacity types × AZs) and the ceiling
(`limits`). Maintaining N nodes is a `Deployment replicas=N`: if spot is reclaimed the pod goes
Pending and Karpenter relaunches. Pin sizes to one-GPU machines and request `nvidia.com/gpu: 1`
so `N pods = N nodes` structurally.

Karpenter *does* have a static-floor mechanism as of v1.8.0 (`NodePool.spec.replicas`, feature
gate `StaticCapacity`) — the earlier "Karpenter has no floor" claim was factually wrong and is
corrected here. But the design decision stands: we do **not** adopt it (see D10). The subject of
"keep N running" remains the pod. A pool needing a true Pod-independent static fleet is served by
a Managed Node Group or a raw NodePool outside this module.

### D8 — No shared top-level defaults; each pool is self-contained

Reject a `node_pool_defaults` merge layer. Intent-derived defaults already absorb the common
values, leaving only 2–3 lines of duplication across pools; a merge layer would add
deep/shallow-merge learning cost and make "where did this value come from" un-traceable in the
tfvars alone. Self-contained pools win for teaching.

### D9 — Device plugin over DRA, because we are Karpenter-based (2026 mid-year)

We keep the device-plugin model: pods request `nvidia.com/gpu` / `vpc.amazonaws.com/efa` /
`aws.amazon.com/neuron` via `resources.limits`, advertised by the NVIDIA GPU Operator, the
aws-efa-k8s-device-plugin, and the Neuron device plugin. This was verified current (not legacy)
against 2026 mid-year primary sources.

Dynamic Resource Allocation (DRA) is the newer path and matters, but it is a **fork in the road,
not a replacement to chase yet**:

- Kubernetes DRA Core API went **GA in 1.34** (Sept 2025), default-on and locked-on in 1.35.
  AWS ships NVIDIA / EFA (DRANET) / Neuron DRA drivers and now *recommends them for new
  deployments* on managed / self-managed node groups.
- **But the DRA drivers do not support Karpenter or EKS Auto Mode** (AWS docs state this
  explicitly; the enabling work is upstream KEP-5004, targeting Kubernetes 1.37 stable). A DRA
  driver and a device plugin cannot coexist on the same node.
- This base is Karpenter-based *by design* (its whole value is flexible mixed procurement — D1).
  Therefore device plugin is not a legacy compromise here; it is **the only correct choice while
  Karpenter is the provisioner**. Device plugin is not deprecated (Kubernetes states device
  plugin and DRA co-exist; replacing the device plugin API is an explicit non-goal).

Consequence: the book teaches the device-plugin model as current, and Advanced01 records "why we
did not choose DRA (= it would mean giving up Karpenter's mixed procurement)". Re-check
`device-management-{nvidia,efa,neuron}.html` at publish time — KEP-5004 could land Karpenter/DRA
support and change this decision. Also note: AL2023 is now **mandatory** (AL2 EKS AMIs retired
2025-11-26), and AWS's own distributed-training reference has shifted its weight to SageMaker
HyperPod on EKS, so "raw EKS + Karpenter" is a deliberately chosen, less-invested-in path.

### D10 — Reject Static Capacity (`spec.replicas`); it conflicts with the mixing thesis

`NodePool.spec.replicas` (v1.8.0, feature gate `StaticCapacity`, still alpha at v1.14) is not
adopted. Three independent conflicts, each sufficient:

1. **Consolidation-exempt vs Intent M.** Static nodes are never consolidated. A static pool with
   `capacity_types` mixed would fix its initial split forever — spot that filled the floor stays
   spot until reclaimed. The "continuously re-optimise the mix" half of Intent M dies.
2. **`replicas` XOR `weight`.** A static pool cannot join the weight-based procurement ordering;
   it becomes an island outside the cluster's procurement graph.
3. **One-way + alpha vs a durable teaching base.** Static→dynamic is irreversible, and the gate
   is alpha (default off). Baking an alpha, irreversible API into a durable base breaks its
   stability contract and invites "forgot to enable the gate → replicas silently no-ops".

Static replicas' genuine niche — "a node must exist even when no pod does" (node-scoped
licensing, bootstrap ordering, migrating a fixed MNG fleet) — matches none of UC1–8. "Always-warm
inference, min N" is served by `Deployment replicas=N` + `do-not-disrupt` + PDB; faster
scale-out is `CapacityBuffer`'s domain (v1.13 alpha, v1beta1 at v1.14), not a floor. Escape
hatch: a team needing a true static fleet adds a raw NodePool outside this module; the base
neither blocks nor supports it. Re-evaluate if `StaticCapacity` graduates and relaxes the
weight/consolidation constraints.

### D11 — Calling a pool from a workload, and multi-pool coordination

How pods *invoke* pools, and whether one job spans several, is a workload-manifest concern, not a
schema concern. The dividing principle: **tfvars is supply (what is available); the manifest is
demand (what is used).** The schema adds nothing for coordination beyond what it already has.

**Invocation — pool name is the stable API.** A pod targets a pool by
`nodeSelector: {node-role: <pool-name>}` plus a toleration for the device-plugin taint
(`nvidia.com/gpu` / `aws.amazon.com/neuron`). Pool name is declared a stable API; renaming a pool
is a breaking change to every manifest that names it. Capability selectors
(`karpenter.k8s.aws/instance-family|instance-size`, `karpenter.sh/capacity-type`) are **not** used
standalone — that scatters a pod non-deterministically across every pool sharing the capability
and bypasses the pool abstraction. Their correct use is **narrowing within a named pool**: on a
pool with mixed `capacity_types`, a pod adds `karpenter.sh/capacity-type: on-demand` to pin the
procurement type inside that pool. "Pool name picks the destination; capability narrows within it."

Per-UC standard: inference (loose F) = Deployment + pool-name nodeSelector + toleration + zone
`topologySpreadConstraints`; distributed training (tight M) = TrainJob/JobSet + pool-name +
explicit `vpc.amazonaws.com/efa` request matching the instance (p5.48xlarge=32, p4d.24xlarge=4,
trn1.32xlarge=8); P/D = pool-name against a single-AZ pool, no spread.

**Multi-pool coordination — possible, with a safety line.** Kubernetes has no first-class "job
spans pools" concept; there is only "each pod picks its pool via nodeSelector, tied together by a
Service or a JobSet". The safe/unsafe line is a single test: **is each pod able to die
independently?**

- **Safe** (async RPC/queue, one side's pod death does not kill the other): P/D disaggregation
  (Prefill on a g5 pool, Decode on a g6 pool — two Deployments + a router Service; the *only*
  added requirement is both pools pinned to the same AZ, already expressible via `zones`);
  preprocess (CPU pool) → train (GPU pool) pipelines; independent trials fanned across
  reserved/spot pools by a Kueue quota (that is *many jobs × many pools*, the correct shape of
  "burst").
- **Unsafe / forbidden**: a single synchronous NCCL/MPI world whose ranks straddle pools —
  e.g. reserved baseline + spot burst in one distributed-training job. One spot reclaim kills the
  whole collective; reliability is rate-limited by the weakest pool, erasing the reserved half.
  **A tightly-coupled collective must live in one pool.**

Recommended shapes: inference coordination = per-role Deployment + Service; training role-split
(e.g. dataloader on CPU pool, trainer on EFA pool) = JobSet with a per-`replicatedJob`
nodeSelector; LeaderWorkerSet is for single-pool multi-node inference only, not pool-spanning.
Gang scheduling is not native to Karpenter (issues #742/#3138 open); use Kueue above it, or await
Workload-Aware Scheduling (KEP-4671/5732, v1.37 beta). **No schema element is added for
coordination** — leaking workload topology into the infra layer is rejected for the same reason
as the `intent` field (D2): intent lives in usage, not in the schema. The one schema contribution
to coordination is same-AZ alignment via `zones`, which already exists.

**Static Capacity re-checked from the invocation axis (still rejected).** "An always-present
destination" looks appealing for resident control-plane pods (Ray head, vLLM router). But the
only delta versus `Deployment replicas + do-not-disrupt` is "a node exists even with zero pods" —
and a resident service by definition always has a pod, so the delta does not apply. First-launch
node wait is a one-time 1–2 min (fine for a resident service); node-survives-pod-death is a
billing drawback, not a feature. Warm-pool-for-scale-out is the overprovisioning (low-priority
pause pod) pattern's domain. D10's rejection holds on this axis too.

## Consequences

- **Backward compatible.** Every legacy field (`capacity_type`, `cb_reservation_id`,
  `interruptible`) is retained and mapped; `zones` unset → `[azs[0]]`. Existing tfvars must show
  a **zero `terraform plan` diff** — this is the CI gate for every implementation phase.
- Contradiction classes caught at plan time by validations/preconditions:
  1. `capacity_reservations` (or legacy `cb_reservation_id`) present but `capacity_types` does
     **not** include `reserved` — the reservation would be silently ignored. NOTE: mixing
     `reserved` **with** `spot`/`on-demand` in one pool is *valid and intended* (Intent F: the
     reservation is consumed by the `reserved` capacity-type, spot/on-demand fill the rest by
     Karpenter's native fallback). Only `reserved`-absent-yet-reservation-present is an error.
  2. effective EFA count > 0 with more than one zone (`["*"]` included).
  3. `interruptible` together with `disruption`.
  4. `efa_interface_count` positive above the type's card ceiling, or a reservation-resolved
     type absent from `instance_types`.
  5. `capacity_type` (legacy single) together with `capacity_types` (new list).
- Multi-AZ availability is available from v1; it was almost cut for "simplicity" and is
  explicitly retained.
- The `ReservedCapacity` Beta gate, reservation-expiry `capacity-type→on-demand` relabel, and
  the CB 10-minute pre-termination drain are documented in the operations chapter.

## Minimal-surface field set (what the book foregrounds)

`instance_types`, `capacity_types`, `capacity_reservations`, `zones`, `efa_interface_count`,
`labels`, `taints`. Everything else (`efa_multi_card`, `disruption`, `consolidate_after`,
`disruption_budget_nodes`, `weight`, `expire_after`, `termination_grace_period`, `volume_size`,
`cpu_limit`, `memory_limit`, `arch`) has a safe derived default and lives in a tuning reference.
Legacy fields are quarantined to a migration appendix. Minimal pool is one line:
`gpu = { instance_types = ["g6.xlarge"] }`.

## One-screen mental model

**"Adding EFA (efa_interface_count > 0) is what makes a pool tight; otherwise it is loose. AZ,
protection, and mixing follow from the fields you already set — plus how your pods pin."**

| Aspect | Loose (`efa_interface_count = 0`) | Tight (`efa_interface_count > 0`) |
|---|---|---|
| AZ | single AZ `azs[0]` (change via `zones`) | single AZ `azs[0]` (forced) |
| placement group | none | cluster (derived) |
| inter-node comms | TCP / ENA (P/D disaggregation) | EFA / RDMA |
| node reclaim | `reclaim` default (per-pod `do-not-disrupt` to protect) | `protect` (no reclaim of running jobs) |
| typical workload | independent jobs, P/D verify, g5/g6 mix | distributed training (NCCL over EFA) |

## Use-case coverage

| UC | Purpose | tfvars sets | Derived | Pod side |
|---|---|---|---|---|
| 1 | stable on-demand | `capacity_types=["on-demand"]` | zones=azs[0], reclaim | — |
| 2 | spot batch | `capacity_types=["spot"]` | zones=azs[0], reclaim | — |
| 3 | Intent F fallback | `capacity_types=["spot","on-demand"]` | zones=azs[0], reclaim | no pin (= F) |
| 4 | Intent M coexistence | `capacity_types=["spot","on-demand"]` | zones=azs[0], reclaim (add `protect` if needed) | **each pod pins capacity-type (= M)** |
| 5 | type-based placement | `instance_types=["g5.xlarge","g5.16xlarge"]` | as above | pods pin `instance-type`/`-size` |
| 6 | tight EFA multi-node | `efa_interface_count`>0, `capacity_reservations` | **protect**, single AZ | optional |
| 7 | loose single-AZ (P/D) | `instance_types=["g5.12xlarge","g6.12xlarge"]` | zones=azs[0], reclaim | pods pin family (Prefill=g5 / Decode=g6) |
| 8 | loose multi-AZ | `capacity_types=["spot","on-demand"]`, `zones=["*"]` | reclaim | replicas=N + topologySpread |

## Phased implementation

1. **Schema + backward-compat mapping.** Add new fields, derive from legacy, exclusivity
   validations. CI gate: zero plan diff on all existing tfvars fixtures. Rendering still legacy.
2. **Validations + `efa_capability` table.** Same-EFA-topology check, single-AZ enforcement for
   EFA/reservation pools, reservation-AZ agreement, `reserved`-requires-reservation. Add small
   GPUs (0/single). Legacy tfvars pass all checks untouched.
3. **Rendering.** Expand `capacity_types`/`zones` into requirements,
   `capacityReservationSelectorTerms`, `weight`, `disruption` presets, EFA placement group +
   `networkInterfaces`, pool label. Ship multi-AZ (UC8) here. e2e: assert spot is not folded onto
   reserved under Intent-M pinning.
4. **Book / runbook.** Intent F vs M as pod-pinning patterns; UC5 nodeSelector examples;
   `do-not-disrupt` vs pool disruption; "weight is not a coexistence guarantee"; reservation
   expiry / CB 10-minute drain; ReservedCapacity Beta note.

## Design notes

Full design rounds are archived outside the repo under the working directory for this design
(`capmix/`); this ADR is the durable summary, the rounds are the audit trail. Fable rounds:
R1 initial → R2 adversarial → R3 concision → R4 third use-case → R5 intent F/M vs fallback →
R6 field naming + "keep N running" scenario → R7 intent-field rejection → R8 Static Capacity
(definition axis) → R9 pool invocation + multi-pool coordination (invocation axis). Legacy-check
was three parallel source-cited web investigations (DRA, Karpenter/Workload-Aware Scheduling, EKS
GPU/batch), all citing primary sources; their key findings are folded into D9/D10/D11.

**Legacy-check verdict (2026 mid-year):** the design is current, not legacy. Karpenter v1.14.0
(2026-07-11), no breaking changes since v1.6; capacity-type list fallback, ODCR/CB
`capacityReservationSelectorTerms`, `networkInterfaces` EFA, `weight`, pod pinning all current
and documented. Device plugin is the only valid choice under Karpenter (DRA drivers do not
support it — D9). FSx Lustre+OpenZFS two-tier, Kubeflow Trainer v2, torchrun all current;
AL2023 mandatory. No Kaniko-style deprecation trap found.
