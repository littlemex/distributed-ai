# EKS for Distributed AI — Accelerator Pools, Capacity Blocks, and EFA

Terraform IaC for an Amazon EKS cluster that runs distributed AI workloads on
NVIDIA GPU and AWS Trainium/Inferentia (Neuron) accelerators. A single
`accelerator_pools` variable describes every accelerated node group; Karpenter
provisions them on On-Demand, Spot, or Capacity Block capacity, with EFA
(Elastic Fabric Adapter) for high-bandwidth multi-node collectives.

The design goal is one reusable module that covers the common accelerated-EKS
shapes — GPU training, GPU/Trainium inference, and Capacity Block campaigns —
without editing resource blocks. You add a workload by adding a map entry.

> New here? Start with the task-oriented **[Usage Guide](./USAGE.md)** (setup,
> running a GPU job, Capacity Blocks, teardown, troubleshooting). This README is
> the reference.

> **This is a reference module, not an official AWS project.** It creates
> billable resources (EKS control plane, NAT gateways, system nodes, and — when
> enabled — accelerators and FSx) that cost money **while they exist, even when
> idle**. Run `terraform destroy` when you are done. See [Cost](#cost) and
> [Known limitations](#known-limitations).

---

## Features

- **`accelerator_pools` — one map, one source of truth.** Each entry renders a
  Karpenter `NodePool` + `EC2NodeClass` via `for_each`. GPU (`nvidia`) and
  Neuron (`neuron`) pools are described uniformly.
- **Mixable capacity types.** `reserved` (Capacity Block), `on-demand`, and
  `spot` can coexist in one cluster — e.g. an On-Demand GPU dev pool, a Spot
  experiment pool, and a reserved Trainium serving pool, all at once.
- **Add-ons follow the pools.** The NVIDIA GPU Operator, the Neuron device
  plugin, and the EFA device plugin each install only if a pool needs them, so a
  GPU-only cluster installs no Neuron components and vice-versa.
- **EFA topology is derived, not hand-entered.** The interface count and
  multi-card layout come from an instance-type lookup table; the module also
  outputs the *schedulable* EFA count a Pod may request (see the p5en gotcha).
- **Single-AZ accelerator placement.** Every accelerator pool pins to one AZ so
  EFA/RDMA collectives stay intra-AZ (they are not routable across subnets).
- **Optional shared storage.** EFS (multi-AZ, ReadWriteMany — a NEFF / Hugging
  Face cache that survives Pod reschedule) and FSx for Lustre (single-AZ,
  high-throughput scratch). FSx is off by default because it bills continuously.
- **Public ingress sample.** AWS Load Balancer Controller + a
  CloudFront → ALB → EKS reference path. Off by default (`enable_demo_app`);
  a base cluster never stands up an internet-facing endpoint.
- **Capacity Block lifecycle.** Helper scripts for offerings/purchase and a
  one-shot EventBridge alarm per reserved pool before its reservation expires.

---

## Architecture

```
VPC (/16 — sized large: GPU/Neuron nodes + EFA-only ENIs consume many IPs)
│
├─ EKS control plane .......... Kubernetes 1.35, IRSA + Pod Identity
│
├─ System managed node group .. m5-class x2: kube-system, Karpenter controller, operators
│
├─ Karpenter NodePools ........ one per accelerator_pools entry, each pinned to a single AZ
│    ├─ gpu / on-demand|spot ... nvidia.com/gpu, EFA (e.g. g6e)
│    ├─ gpu / reserved (CB) ..... nvidia.com/gpu, EFA multi-card (e.g. p5en = H200 x8)
│    └─ neuron / reserved (CB) .. aws.amazon.com/neuron, EFA multi-card (e.g. trn2)
│
├─ Add-ons (conditional) ...... GPU Operator · Neuron plugin · EFA plugin
└─ Storage (optional) ......... EFS (RWX, multi-AZ) · FSx for Lustre (single-AZ scratch)
```

---

## The `accelerator_pools` variable

This is the core abstraction. One map entry == one accelerated node group.
`karpenter-resources.tf` renders an `EC2NodeClass` and a `NodePool` per entry
with `for_each`; the add-on modules key off `device_plugin` and the derived EFA
topology.

| Field | Meaning |
|---|---|
| `instance_types` | List of EC2 types Karpenter may launch, e.g. `["g6e.12xlarge"]` or `["g6e.12xlarge","g6e.24xlarge"]`. All types in a pool must share one EFA topology (validated). The first entry drives EFA derivation. |
| `device_plugin` | `nvidia` or `neuron`. Selects the device-plugin add-on and the resource pods request (`nvidia.com/gpu` vs `aws.amazon.com/neuron`). |
| `capacity_type` | `reserved` (Capacity Block), `on-demand`, or `spot`. |
| `zone` | Single AZ (one of `var.azs`). All pools pin here — EFA is intra-AZ only and Capacity Block is single-AZ. There is no cross-AZ fallback. |
| `efa_interface_count` | `-1` (default) derives from the instance type; set to override; `0` disables EFA. |
| `efa_multi_card` | `null` (default) derives; `true` = one EFA per card (p5/p5en/trn2); `false` = single card (g6e). |
| `cb_reservation_id` | `cr-…` — required when `capacity_type = "reserved"`. |
| `cb_end_date` | Optional RFC3339 expiry → schedules a per-pool pre-expiry SNS alert. |
| `ami_alias` / `ami_ssm_parameter` | AMI selection. `ami_ssm_parameter` (e.g. the Neuron AL2023 AMI SSM path) overrides `ami_alias`. |
| `volume_size`, `expire_after`, `consolidate_after`, `cpu_limit`, `memory_limit` | Root EBS size, node lifetime, empty-node consolidation delay (defaults per capacity type), and NodePool limits. |

Validations enforce: RFC1123 pool keys, non-empty `instance_types`,
`device_plugin ∈ {nvidia, neuron}`, `capacity_type ∈ {reserved, on-demand, spot}`,
`zone ∈ var.azs`, and `reserved ⇒ cb_reservation_id`. A precondition additionally
rejects a pool whose `instance_types` mix EFA topologies.

### Schedulable EFA (important)

With the multi-card layout, network card 0 carries the node IP and is **not**
advertised as EFA, so a p5en.48xlarge (16 cards) advertises **15**
`vpc.amazonaws.com/efa`, not 16. Requesting 16 leaves the Pod unschedulable.
The module computes this for you:

```bash
terraform output accelerator_pool_efa_schedulable
# { "gpu-p5en" = 15, "gpu-dev" = 1 }
```

### Example: three pools in one cluster

```hcl
accelerator_pools = {
  # On-Demand GPU dev pool — always-available L40S for iteration.
  gpu-dev = {
    instance_types = ["g6e.12xlarge"]
    device_plugin  = "nvidia"
    capacity_type  = "on-demand"
    zone           = "us-east-2a"
    # EFA derived: 1 interface, single-card.
  }

  # Capacity Block GPU pool — H200 for a scheduled multi-node campaign.
  gpu-p5en = {
    instance_types    = ["p5en.48xlarge"]
    device_plugin     = "nvidia"
    capacity_type     = "reserved"
    zone              = "us-east-2a"
    cb_reservation_id = "cr-REPLACE_ME"
    cb_end_date       = "2026-01-01T12:00:00Z" # optional pre-expiry alert
    volume_size       = "500Gi"
    # EFA derived: 16 interfaces, multi-card (15 schedulable).
  }

  # Capacity Block Trainium pool — Neuron serving.
  trn2-serving = {
    instance_types    = ["trn2.48xlarge"]
    device_plugin     = "neuron"
    capacity_type     = "reserved"
    zone              = "us-east-2b"
    cb_reservation_id = "cr-REPLACE_ME"
    ami_ssm_parameter = "/aws/service/eks/optimized-ami/1.35/amazon-linux-2023/x86_64/neuron/recommended/image_id"
    volume_size       = "500Gi"
  }
}
```

### Conditional add-ons

The add-on stack is derived from the pools (see `locals.tf`):

| Local | True when | Installs |
|---|---|---|
| `has_gpu_pool` | any pool `device_plugin = "nvidia"` | NVIDIA GPU Operator |
| `has_neuron_pool` | any pool `device_plugin = "neuron"` | neuron-helm-chart (device plugin) |
| `has_efa_pool` | any pool with EFA | aws-efa-k8s-device-plugin |

---

## Reference results

Smoke-scale runs performed on this module to validate the environment
(2026-07, us-east-2, single 2-AZ VPC). Not benchmarks — the point is that each
path works end to end.

| Workload | Where | Result |
|---|---|---|
| PyTorch DDP (gloo) | CPU pool, 2 nodes | Completed; loss decreased; checkpoint written to shared storage. |
| FSDP, Llama-3.2-1B | 1× p5en.48xlarge (8× H200) | Completed; ~99 TFLOPS/GPU, ~114k tokens/s; EFA transport confirmed in NCCL logs (`aws-ofi-nccl` / libfabric). |
| vLLM inference (Cosmos-Reason1-7B) | 1× H200 | Server healthy; OpenAI-compatible inference responses. |
| slime (Megatron + SGLang GRPO) | p5en | Images built + pushed, KubeRay + manifests prepared. The GRPO run itself needs ≥2 nodes and was left for a multi-node Capacity Block. |

---

## Prerequisites

| Tool | Minimum |
|---|---|
| Terraform | 1.9+ |
| AWS CLI | 2.15+ |
| kubectl | 1.29+ |
| helm | 3.14+ |
| python3 | 3.10+ (helper scripts) |

Terraform provider constraints live in `versions.tf`; the `terraform-aws-eks`
module version and component chart versions (Karpenter 1.13.0, GPU Operator,
EFA plugin, etc.) are pinned as defaults in `variables.tf`. IAM: permissions to
create EKS, EC2/VPC, IAM roles, and (for Capacity Block)
`ec2:*CapacityReservation*` / `ec2:*CapacityBlock*`.

`terraform destroy` additionally requires `bash`, the AWS CLI, and `kubectl` on
`PATH` on the machine running Terraform: a destroy-time provisioner
(`null_resource.wait_for_node_drain` in `karpenter.tf`) uses them to confirm
every accelerator node has actually terminated before removing Karpenter — see
[Known limitations](#known-limitations).

```bash
aws sts get-caller-identity   # confirm the intended account and region first
```

Generate an inputs/outputs reference with
[`terraform-docs`](https://terraform-docs.io): `terraform-docs markdown .`

---

## Quick start (no Capacity Block, no FSx)

`accelerator_pools` defaults to empty and FSx is off, so the base cluster is
Region-agnostic and cheap to stand up. Supply one On-Demand GPU pool in
`terraform.tfvars`:

```bash
cd infra/eks
cp terraform.tfvars.example terraform.tfvars   # edit region, azs, and one pool
terraform init
terraform apply                                # ~15 min

aws eks update-kubeconfig --name "$(terraform output -raw cluster_name)" --region <region>
kubectl get nodes
```

Karpenter provisions a GPU node when the first pod requesting `nvidia.com/gpu`
is scheduled.

---

## Capacity Block workflow

```bash
# 1. Find an offering for your instance type / duration / AZ.
./scripts/00-check-cb-offerings.sh

# 2. Purchase (prints the price; confirms before buying). Requires budget approval.
./scripts/01-purchase-cb.sh --offering-id <id> --instance-type p5en.48xlarge --instance-count 2

# 3. Add a reserved pool to accelerator_pools with cb_reservation_id = "cr-…"
#    (and optionally cb_end_date), then apply. 02-post-purchase.sh prints a ready-to-paste
#    pool block from the purchased reservation:
./scripts/02-post-purchase.sh --cr-id cr-… --end-date <RFC3339> --instance-type p5en.48xlarge --zone <az>
terraform apply
kubectl get nodes -l karpenter.sh/capacity-type=reserved

# 4. Verify NCCL / EFA before the real run.
./scripts/03-verify-nccl.sh --nodes 2 --gpus-per-node 8
#    Expect a high busbw and "NET/OFI Selected provider is efa" in the logs.

# 5. Teardown (NodePool only, or full destroy).
./scripts/04-teardown.sh
./scripts/04-teardown.sh --destroy
```

Each reserved pool that sets `cb_end_date` gets a one-shot EventBridge alarm to
an SNS topic one hour before its reservation ends
(`eventbridge-cb-alarm.tf`).

---

## Neuron (Trainium / Inferentia)

Set `device_plugin = "neuron"` on a pool and point `ami_ssm_parameter` at the
Neuron AL2023 EKS AMI (the driver ships in that AMI; only the device plugin is
installed). Pods request whole devices via `aws.amazon.com/neuron: "<n>"`.
For tensor-parallel serving across many chips, set
`neuron_enable_scheduler = true` so the Neuron scheduler extension allocates
contiguous device IDs. See `manifests/neuron-serving-vllm.yaml.tpl`.

> Multi-node Neuron over EFA is wired (the EFA device plugin tolerates the
> Neuron taint) but has not been hardware-verified in this module — see
> [Known limitations](#known-limitations).

Two components commonly paired with GPU/Neuron inference are deliberately
**not** included — they are workload-layer concerns, not cluster infra:

- **KEDA**, for scale-to-zero autoscaling (e.g. a vLLM Deployment that scales
  Pod replicas with request rate/queue depth down to zero). Install it
  separately; its `ScaledObject` drives the Deployment, and Karpenter (this
  module) provisions the node underneath once KEDA scales past zero.
- **Mountpoint for Amazon S3 CSI driver**, for mounting model weights directly
  from S3. This module ships EFS and FSx for shared/scratch storage (see
  above) but not an S3 mount — add the `aws-mountpoint-s3-csi-driver` EKS
  addon the same way `efs.tf` adds the EFS one, if your workload needs it.

---

## CloudFront → ALB → EKS demo endpoint (opt-in)

Off by default (`enable_demo_app = false`). Setting it to `true` provisions
the AWS Load Balancer Controller and a sample public path:
`Client (HTTPS) → CloudFront → ALB (internet-facing) → EKS Pod`. `alb-controller.tf`
and `cloudfront.tf` gate every resource on this variable so that a base cluster
never stands up an internet-facing, unauthenticated endpoint. The demo Pod is
pinned to the CPU NodePool via `nodeSelector`, so pair it with
`cpu_nodepool_enabled = true` or it stays `Pending`.

The ALB security group only allows the CloudFront managed prefix list, and
CloudFront adds an `X-Origin-Verify` header the ALB checks (the value is
generated by `random_password`, never written to a YAML file). Because the
`aws_lb` data source needs the ALB at plan time, it is a two-phase apply:

```bash
terraform apply -var enable_demo_app=true                              # phase 1: ALB Controller + demo app + ALB
terraform apply -var enable_demo_app=true -var enable_cloudfront=true  # phase 2: CloudFront + SG lock-down
```

### Production hardening

This is a demo, not a production endpoint. Before production use: add HTTPS on
the ALB (ACM) and switch `origin_protocol_policy` to `https-only`, consider
CloudFront VPC Origins to keep the ALB internal, and attach a WAFv2 WebACL via
`cloudfront_web_acl_id`.

---

## Gotchas

Discovered by direct measurement and cluster inspection.

### Capacity Block & Karpenter

| Symptom | Root cause | Fix |
|---|---|---|
| Karpenter never provisions CB nodes | NodePool used `capacity-type=capacity-block` | Use `karpenter.sh/capacity-type In [reserved]` (Karpenter v1 value). |
| CB nodes not matched | `EC2NodeClass.capacityReservationSelectorTerms` missing/wrong | Set `[{id: "cr-…"}]` exactly as returned by the purchase API. |
| `reserved` pool still "filtered out all instance types" | The reservation slot is not yet free | Wait until the previously-running instance fully terminates; the slot frees, then Karpenter launches. |
| `featureGates.reservedCapacity` rejected by Helm | Not a value key in the v1.13 chart | Remove it — `ReservedCapacity` is the compiled default. |
| `expireAfter` rejected | ISO-8601 duration not accepted | Use a Go duration string, e.g. `"24h"`. |
| Karpenter CRDs/NodeClaims vanish on a shared cluster | An unrelated Helm chart removed Karpenter's CRDs, cascading to every NodeClaim | `terraform taint` + apply the Karpenter releases and NodePool/EC2NodeClass. If a NodeClass is stuck `Terminating` on a finalizer, remove the stuck NodeClaim's finalizer first. This module installs the `karpenter-crd` chart separately so CRDs upgrade with the version. |
| hugepages request blocks provisioning | A Pod requesting `hugepages-*` finds no matching instance type | Remove the hugepages request unless the node is configured for it. |
| CB expiry alert schedule silently disappears | The schedule fires once (`action_after_completion = "DELETE"`) and self-deletes; a pool whose alert time has already passed is also excluded from `for_each` so `apply` never tries to recreate an `at()` expression in the past | Expected — the alert already fired (or the window passed). Set a new `cb_end_date` for the next reservation. |
| `terraform apply` fails: `cb_end_date must be UTC` | `cb_end_date` was not RFC3339 UTC (`Z` suffix — validated) | Use a UTC timestamp, e.g. `"2026-01-01T12:00:00Z"`. |
| `terraform destroy` run with a live accelerator node pauses on `null_resource.wait_for_node_drain` for up to 30 minutes, or fails there | Node drain + EC2 termination is async work done by the Karpenter controller; `kubectl_manifest` reports a NodePool/NodeClaim delete "complete" as soon as the Kubernetes API accepts it, well before that finishes | Expected — this resource polls `kubectl get nodeclaims` (up to 30 min) before Karpenter, the device plugins, the EFS/FSx CSI drivers, and the EFA security group are removed, so nothing that owns a per-node AWS resource disappears while a node still exists. A measured single-node drain took ~9.5 minutes. If it fails after 30 minutes, a node is genuinely stuck — check `kubectl get nodeclaims` / `aws ec2 describe-instances` before re-running destroy. |
| The drain-wait above never resolves even though the node's EC2 instance is already gone | Karpenter's controller Pod runs in a private subnet; if the NAT gateway becomes unavailable while the controller is still finalizing a NodeClaim, every AWS API call it makes (EC2, IAM, STS, SSM) times out and it can never clear the finalizer — discovered live during this module's own destroy testing, when the NAT gateway (unrelated to Karpenter in Terraform's dependency graph) was removed mid-drain | This module adds Interface VPC endpoints for EC2/STS/SSM (`vpc-endpoints.tf`) specifically so Karpenter keeps working even if the NAT is gone; `null_resource.wait_for_node_drain` depends on them so they outlive the wait. IAM has no regional Interface endpoint (it's a global service), so IAM calls (e.g. `ListInstanceProfiles`) still need the NAT — this residual risk is not fully closed. If you still hit this, check `kubectl -n karpenter logs` for `i/o timeout` errors — that confirms the API-connectivity theory — and retry destroy once resolved. |
| `terraform destroy` fails: `helm_release.karpenter_crd` uninstallation `context deadline exceeded`, `kubectl get ec2nodeclass` still shows objects | An EC2NodeClass's `karpenter.k8s.aws/termination` finalizer is cleared by Karpenter's controller only after it successfully calls IAM (`ListInstanceProfiles`) — same NAT/IAM gap as the row above, but for EC2NodeClass instead of NodeClaim. `null_resource.wait_for_node_drain` waits for this best-effort (does not fail the destroy on its own timeout) precisely because it's known not to resolve without a NAT | Harmless — the underlying EC2 instance is already confirmed terminated by that point. Clear the stuck finalizer and re-run destroy: `kubectl patch ec2nodeclass <name> --type=merge -p '{"metadata":{"finalizers":[]}}'`. |

### EFA & NCCL

| Symptom | Root cause | Fix |
|---|---|---|
| p5en Pod never schedules requesting `efa: 16` | Card 0 = `interface`, so the node advertises **15** EFA | Request ≤ `terraform output accelerator_pool_efa_schedulable`. |
| NCCL falls back to TCP (much slower) | Positive `NCCL_SOCKET_IFNAME` hides EFA interfaces | Use an exclusion pattern: `NCCL_SOCKET_IFNAME=^lo,docker,veth`. |
| `fi_info -p efa` empty in a Pod | Pod missing the EFA resource request | Add `limits: {vpc.amazonaws.com/efa: "<n>"}` and the EFA toleration. |
| EFA device-plugin chart/app version confusion | Chart version ≠ app/image version | Pin the chart version; do not substitute the app version. |

### Data & Hugging Face

| Symptom | Root cause | Fix |
|---|---|---|
| Hugging Face `429` even with a valid token | HF rate-limits by egress IP; `/api/` (dataset tree, xet) throttles under many concurrent ranks | Set `HF_HUB_DISABLE_XET=1`; pre-stage the tokenizer + a few dataset shards to shared storage (file `resolve` still works) and load the dataset from a local dir. |

### Operational

| Symptom | Root cause | Fix |
|---|---|---|
| `kubectl` acts on the wrong cluster | Multi-cluster account; context silently switched | Always check `kubectl config current-context` before operating. |
| Large accelerator image build fails: "no space left" | A small local VM disk cannot hold NGC-based images | Build on a GPU node (large NVMe) with a privileged buildkit pod, pushing straight to ECR. |
| sshd/torchrun dies (exit 143) under `kubectl exec` | Background process killed when the exec session closes | Run it as the Pod's `command:` (PID 1 subtree), not inside `exec`. |
| CPU nodes never join | Discovery tag on public subnets → Karpenter picks a no-egress subnet | Scope `karpenter.sh/discovery` to private subnets only (this module does). |
| `terraform apply`: CRD not ready | NodePool applied before the Karpenter webhook is up | `depends_on` on the CRD resources (this module does). A first apply can occasionally need a re-apply if the API is momentarily slow to serve the new types. |

---

## Cost

Rough guidance — check current pricing for your Region:

- **Always-on while the cluster exists:** EKS control plane (~$0.10/h), NAT
  gateway(s), the system managed node group, and 3 Interface VPC endpoints
  (EC2/STS/SSM — ~$0.01/h each; the S3 Gateway endpoint is free). The
  endpoints exist so Karpenter keeps working if the NAT gateway is ever
  unavailable during teardown — see the Gotchas row on destroy ordering.
- **FSx for Lustre** (when `fsx_enabled = true`): PERSISTENT_2 SSD bills for the
  full provisioned capacity continuously — this is why it is off by default.
- **Accelerators:** On-Demand GPU/Neuron nodes bill per hour while running;
  on-demand/spot pools consolidate empty nodes after a short idle by default.
  **Capacity Block** is billed upfront at purchase for the whole reserved window.

Run `terraform destroy` after a campaign to stop ongoing charges. Teardown
deletes FSx/EFS and their contents (regenerable caches) — see below.

---

## Known limitations

- **Multi-node Neuron over EFA is untested** on this module (single-node Neuron
  and multi-node GPU are verified).
- **Kubernetes-provider first-apply flake:** NodePool/EC2NodeClass occasionally
  need a second `apply` if the Karpenter CRDs are not yet Established.
- **CRD upgrades:** the `karpenter-crd` chart is installed separately so CRDs
  track the chart version; still review CRD changes when bumping versions.
- **Terraform state contains secrets** (the CloudFront `X-Origin-Verify` value,
  transient ECR tokens). Use an encrypted remote backend (S3 + KMS) for anything
  beyond local experimentation.
- **Teardown deletes data:** FSx/EFS have no `prevent_destroy` (so the
  environment is disposable). Set it, or back up, before storing anything you
  cannot regenerate.
- The `data.http` fetch for the ALB Controller IAM policy is a plan-time network
  dependency; the MPI operator manifest is vendored (committed) to avoid one.
- **FSx is static-provisioning only:** aws-fsx-csi-driver cannot dynamically bind
  a StorageClass to an existing filesystem (only create new ones), so this
  module creates one filesystem and one fixed-`volumeHandle` PersistentVolume
  (`fsx-training`) — no `fsx-lustre` StorageClass. Bind a PVC to it by name.
- **`terraform destroy` requires `bash` + AWS CLI + `kubectl` on the local
  machine's `PATH`.** A destroy-time provisioner polls for accelerator nodes to
  fully drain before removing Karpenter and its addons (see the Gotchas row
  above); if any of those tools are missing, the provisioner fails loudly
  (`exit 1`) rather than silently skipping the safety check. This module has
  not been exercised with a non-bash shell or on Windows.
- **`terraform destroy` can fail once on `helm_release.karpenter_crd` if the
  NAT gateway is already gone** when an EC2NodeClass's finalizer is still
  waiting on an IAM call (see the Gotchas row above). Confirmed live: EC2
  instances are unaffected (already terminated by that point); clear the
  finalizer and re-run destroy.

---

## Shared-cluster safety

On a shared or borrowed account, treat this cluster as one of several. Before
any change: confirm `kubectl config current-context`, avoid installing Helm
charts that own cluster-scoped CRDs you do not manage (they can delete another
tool's CRDs), and never force-push infra changes without checking who else
operates the environment.

---

## License

Sample/reference code provided as-is under the repository's license. Not an
official AWS project; no support or SLA is implied. Review and harden before any
production use.
