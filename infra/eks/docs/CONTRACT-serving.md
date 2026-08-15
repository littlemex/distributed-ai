# CONTRACT: Neuron vLLM serving — infra/eks ⇄ workload templates (v1)

This document is the single source of truth for the boundary between **this cluster infra
(`distributed-ai/infra/eks`)** and the **serving templates that run on top of it** (currently
`littlemex/aws-neuron-samples/setup/multi-node/eks`, but any caller). The rule that decides which
side owns a thing:

> **If it cannot be swapped without rebuilding the cluster, it belongs to infra. If `kubectl delete`
> removes it, it belongs to the workload templates.**

CRDs, controllers, the scheduler, device plugins, and the storage backends are infra. Deployments,
LeaderWorkerSets, per-model config, and `up.sh` are the workload side. A template consumes this
contract; it does not reach into Terraform. `up.sh` **preflight** turns every clause below into an
executable check and fails with an actionable `[NG]` when infra does not satisfy the declared
contract version.

Status legend: **[live]** already provided by infra today · **[v1-add]** added by the serving
enablement change that ships this contract.

---

## 1. Node scheduling

A serving pod targets a Neuron Karpenter pool by the module-owned labels (set last so a pool cannot
override them — `karpenter-resources.tf`):

| label | value | status |
|---|---|---|
| `node-role` | the `accelerator_pools` key (e.g. `trn2`, `trn2-3x`) | [live] |
| `distributed-ai/device` | `neuron` | [live] |

Required tolerations (accelerator nodes are tainted device-first; CB pools add a rotating
`capacity-reservation` taint):

```yaml
tolerations:
  - { key: aws.amazon.com/neuron, operator: Exists, effect: NoSchedule }
  - { key: vpc.amazonaws.com/efa, operator: Exists, effect: NoSchedule }
  - { key: capacity-reservation,  operator: Exists, effect: NoSchedule }
```

To pin onto reserved (Capacity Block) capacity and never fall back to on-demand, also set
`nodeSelector: { karpenter.sh/capacity-type: reserved }`. **[live]**

## 2. Accelerator resources

- `aws.amazon.com/neuron: "<n>"` in **both** requests and limits — whole-device granularity (one
  request per whole trn2 chip). **[live]**
- `vpc.amazonaws.com/efa: "<n>"` only when `n > 0`. EFA is meaningful only for genuine inter-node
  traffic; single-node tensor parallelism uses on-chip NeuronLink, not EFA, so single-node serving
  requests `0`. **[live]**
- Do **not** request hugepages on a pod that is expected to trigger new-node provisioning (Karpenter
  does not size a new node against hugepages, so the NodeClaim never gets created). **[live]**
- Size the `memory` request/limit for **peak NEFF-compile RAM**, not just steady-state inference. A
  52-layer hybrid cold-compiling with parallel trace workers has OOM-killed the kubelet on a
  128 GB / 12 vCPU node. Templates should set `VLLM_NEURON_PARALLEL_TRACE_WORKERS=1` for large models
  (slower compile, bounded RAM) — see §7. **[live, documented in feedback-neuron-serving-cache-pvc.md]**

## 3. Capability matrix (never hardcode instance types)

Infra publishes per-pool capability; the template resolves `pool → devices/node, EFA cards, LNC`
from the live cluster, not from a hardcoded table. Discovery (authoritative at runtime):

```bash
kubectl get nodes -l node-role=$POOL \
  -o jsonpath="{.items[0].status.allocatable['aws\.amazon\.com/neuron']}"     # devices/node
kubectl get nodes -l node-role=$POOL \
  -o jsonpath="{.items[0].status.allocatable['vpc\.amazonaws\.com/efa']}"     # EFA cards/node
```

or `terraform output accelerator_pool_efa_schedulable`. Templates MUST derive TP/PP degrees from
this, honoring the fork-wide "no hard-coded identifiers" rule. **[live]**

## 4. Model / NEFF artifact cache (storage)

- Infra provisions one **fixed-name RWX PVC `neuron-artifact-cache`** bound to a Retain, static PV
  (EFS preferred for cross-AZ survival of the cache; OpenZFS/Lustre acceptable single-AZ). The name
  is published as a Terraform output. **[v1-add]** (today the chart only references a cache PVC in a
  comment and ships no PVC — the known gap in `feedback-neuron-serving-cache-pvc.md`.)
- The cache **key layout inside** the volume is owned by the template, NOT infra:
  `/<neuron-sdk-version>/<model-id>/<tp>x<pp>/...`. The SDK version and the parallelism degrees MUST
  be part of the key. Omitting them makes a template pick up a checkpoint compiled for a different
  SDK or a different TP/PP and fail with opaque runtime errors. **[template responsibility]**
- The PVC is created once per namespace by infra/operator; the template binds `existingClaimName`
  and never auto-creates/deletes it (a static Retain PV only re-binds to the exact PVC UID it last
  held — a wrong-namespace or template-owned PVC leaves orphaned Released PVs that block
  `terraform destroy`). **[live constraint]**

## 5. Multi-node serving primitive

- `mode: multi` templates use **LeaderWorkerSet** (`leaderworkerset.x-k8s.io/v1`), installed and
  version-pinned by infra as a cluster addon (same tier as Karpenter / neuron-helm-chart). A
  template requires only that the LWS v1 API is present; it never installs the controller. **[v1-add]**
- Hand-rolled N-Deployment + headless-Service rendezvous (as the GPU `vllm-ray` demo does) is a
  reference/anti-pattern, not a supported serving primitive — it has no group semantics (atomic
  restart, stable leader address, gang scheduling). Do not port it to Neuron.
- Default topology for a model too large for one node: **TP within a node (NeuronLink) × PP across
  nodes (EFA)**. Cross-node TP is an experiment flag only (all-layer all-reduce over EFA is
  latency-hostile). The per-model schema separates `tp_intra` and `pp_inter` from the start.
- Gang-provisioning caveat: on Capacity Block pools Karpenter may satisfy only part of an
  N-node group, leaving the LWS half-scheduled and the leader waiting forever. The template preflight
  checks pool capacity vs `--nodes` and uses a bounded rollout wait that returns `[NG]`.

## 6. Neuron Scheduler Extension

The Neuron Scheduler Extension (contiguous NeuronCore-ID allocation) is **required whenever a Neuron
pool exists** — multi-device tensor parallelism breaks or silently degrades on non-contiguous core
allocation. Infra enables it by default for Neuron pools (no longer an opt-in). The template
preflight treats its absence as `[NG]`, not a warning. **[v1-add: promote from optional to
mandatory-when-neuron]**

## 7. Image ⇄ driver version compatibility

The serving container's Neuron SDK (vLLM-Neuron image) and the node AMI's Neuron driver must be
compatible. A drift here produces the worst failure class: "runs, but collectives are slow / flaky."
Infra pins the node AMI via the pool's `ami_ssm_parameter`/`ami_alias`; the template owns the
container image (SDK-pinned). This document carries the compatibility table (AMI Neuron release ↔
container SDK release ↔ vLLM-Neuron plugin version); update it whenever either side moves.

| node AMI (Neuron release) | container Neuron SDK | vLLM-Neuron plugin | verified |
|---|---|---|---|
| _fill on first validated pairing_ | | | |

## 8. Capacity Block lifecycle

Capacity Block nodes are force-terminated by EC2 **30 minutes before** the reservation end — not at
the end. Infra currently only emits an SNS alert 1h before `cb_end_date` (no automatic cordon/drain);
Karpenter's `reservedCapacity` is expected to drain shortly before reclaim but this is unverified for
serving pods. Until an infra-side pre-expiry drain lands (tracked as infra homework), the template:
- shows the CB end time and the T-30min reclaim time in preflight,
- sets a `preStop` + graceful shutdown on the serving container,
- persists NEFF + weights to `neuron-artifact-cache` (§4) so a reclaimed node does not force a full
  recompile on the replacement.

## 9. Preflight checklist (executable contract)

`up.sh` preflight verifies, and fails `[NG]` with a specific remediation if any is missing:

1. kubeconfig reachability + target namespace exists.
2. LWS CRD present (`leaderworkerset.x-k8s.io/v1`) — for `mode: multi`.
3. Neuron device plugin, Neuron Scheduler Extension, and EFA device plugin DaemonSets are Ready.
4. `neuron-artifact-cache` PVC is `Bound` in the target namespace.
5. Target pool label (`node-role=<pool>`) resolves to at least one schedulable node OR Karpenter can
   provision it, and allocatable `aws.amazon.com/neuron` / `vpc.amazonaws.com/efa` meet the requested
   TP/PP/nodes.
6. For CB pools: reservation is `active` and has capacity for `--nodes`; report the reclaim time.

## 10. Versioning

This contract is **v1**. A template declares the contract version it requires; `up.sh` refuses to
run against an infra that advertises an older version. Breaking changes bump the major version. The
capability matrix (§3), the cache PVC name (§4), the LWS apiVersion (§5), and the scheduler
requirement (§6) are the load-bearing clauses — changing any of them is a major bump.
