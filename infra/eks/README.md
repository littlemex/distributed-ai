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
> billable resources (EKS control plane, NAT gateways, system nodes, the two
> default-on FSx filesystems, and — when enabled — accelerators) that cost money
> **while they exist, even when idle**. Run `terraform destroy` when you are
> done. See [Cost](#cost) and [Known limitations](#known-limitations).

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
- **AZ config is derived from the region, not hand-maintained.** Set only
  `region`: the VPC auto-spans every standard AZ in it, and one private + one
  public subnet CIDR per AZ is auto-carved from `vpc_cidr` (`az.tf`). Because the
  VPC covers the whole region, a Capacity Block landing in *any* AZ always has a
  matching subnet — so a CB moving between AZs (which happens routinely across
  reservations) needs no edit here. `azs` / the subnet-CIDR lists remain optional
  escape hatches for pinning a specific AZ set or layout.
- **Single-AZ accelerator placement, auto-pinned.** Every accelerator pool pins
  to one AZ so EFA/RDMA collectives stay intra-AZ (they are not routable across
  subnets), but you don't write the AZ: a `reserved` pool derives it from its
  Capacity Block reservation, and an `on-demand`/`spot` pool defaults to the
  first cluster AZ. Set `zone` explicitly only to override.
- **Two-layer single-AZ shared storage, on by default.** FSx for OpenZFS
  (single-AZ NFS home/shared `/shared`) and FSx for Lustre (single-AZ,
  high-throughput scratch) — the awsome-distributed-ai two-layer design. Both
  bill continuously (hence "even when idle" above), but they are on by default
  because the workloads have nothing to write to otherwise. EFS (regional,
  multi-AZ, ReadWriteMany) is demoted to opt-in for the one case that needs
  cross-AZ RWX — a NEFF / Hugging Face cache that must survive a Pod rescheduled
  into another AZ. In a cluster that pins every accelerator to one AZ, a
  multi-AZ filesystem is the anomaly, not the default.
- **CSI drivers are permanent infra, decoupled from the filesystems.** The EBS,
  FSx (OpenZFS + Lustre), and EFS CSI drivers all install unconditionally as
  cluster capabilities; `openzfs_enabled` / `fsx_enabled` / `efs_enabled` gate
  only whether each *filesystem* (and its static PV) is created. This is one
  instance of the module's base-layer invariant — see below.
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
├─ CSI drivers (always on) .... EBS · FSx OpenZFS · FSx Lustre · EFS (drivers; filesystems gated separately)
└─ Storage .................... FSx OpenZFS (single-AZ NFS /shared, default on) · FSx Lustre (single-AZ scratch, default on) · EFS (multi-AZ RWX, opt-in)
```

---

## Base-layer invariant

One rule governs what this module installs: **everything a workload depends on
at runtime is permanently managed by Terraform.** CSI drivers, the Kubeflow
Training Operator, the Karpenter controller, and the shared-storage static PVs
are cluster infrastructure that lives for the cluster's lifetime — they are not
created and torn down alongside the Pods that use them. This is why the
per-workload docs can assume "it's already there after `terraform apply`."

Two consequences worth calling out explicitly:

- **CSI driver ≠ filesystem.** The drivers install unconditionally; the
  `*_enabled` flags gate only the filesystems. A driver is a cluster
  capability, so it stays available even when its filesystem is off — enabling
  EFS later is then "add one filesystem," not "add an addon."
- **No CD mechanism is bundled, by design.** There is no Argo CD / Flux /
  GitOps controller here. Because every runtime prerequisite is held by
  Terraform, running a workload is just `helm template … | kubectl apply -f -`;
  a continuous-delivery controller is not a base-layer dependency. Its absence
  is a consequence of pushing prerequisites into Terraform, not a missing
  feature. Layer GitOps on top if you want it — it is a consumer of this base,
  not something the base depends on.

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
| `zone` | Single AZ the pool pins to. **Leave unset** — it is derived: `reserved` → the Capacity Block's AZ (read from the reservation at plan time); `on-demand`/`spot` → the first cluster AZ. All pools pin to one AZ (EFA is intra-AZ only, a Capacity Block is single-AZ); there is no cross-AZ fallback. Set an explicit AZ (one of the resolved cluster AZs) only to override the default. |
| `efa_interface_count` | `-1` (default) derives from the instance type; set to override; `0` disables EFA. |
| `efa_multi_card` | `null` (default) derives; `true` = one EFA per card (p5/p5en/trn2); `false` = single card (g6e). |
| `cb_reservation_id` | `cr-…` — required when `capacity_type = "reserved"`. |
| `cb_end_date` | Optional RFC3339 expiry → schedules a per-pool pre-expiry SNS alert. |
| `ami_alias` / `ami_ssm_parameter` | AMI selection. `ami_ssm_parameter` (e.g. the Neuron AL2023 AMI SSM path) overrides `ami_alias`. |
| `volume_size`, `expire_after`, `consolidate_after`, `cpu_limit`, `memory_limit` | Root EBS size, node lifetime, empty-node consolidation delay (defaults per capacity type), and NodePool limits. |

Validations enforce: RFC1123 pool keys, non-empty `instance_types`,
`device_plugin ∈ {nvidia, neuron}`, `capacity_type ∈ {reserved, on-demand, spot}`,
and `reserved ⇒ cb_reservation_id`. Preconditions in `az.tf` additionally enforce
that every pool's *resolved* `zone` is one of the cluster AZs and reject a pool
whose `instance_types` mix EFA topologies.

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
    # zone omitted → first cluster AZ. EFA derived: 1 interface, single-card.
  }

  # Capacity Block GPU pool — H200 for a scheduled multi-node campaign.
  gpu-p5en = {
    instance_types    = ["p5en.48xlarge"]
    device_plugin     = "nvidia"
    capacity_type     = "reserved"
    cb_reservation_id = "cr-REPLACE_ME"        # zone comes from this reservation
    cb_end_date       = "2026-01-01T12:00:00Z" # optional pre-expiry alert
    volume_size       = "500Gi"
    # EFA derived: 16 interfaces, multi-card (15 schedulable).
  }

  # Capacity Block Trainium pool — Neuron serving.
  trn2-serving = {
    instance_types    = ["trn2.48xlarge"]
    device_plugin     = "neuron"
    capacity_type     = "reserved"
    cb_reservation_id = "cr-REPLACE_ME"        # zone comes from this reservation
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

## State management

This module uses local Terraform state by default: a plain `terraform init` with
no backend configuration keeps state in `terraform.tfstate`, which is convenient
for short-lived experiments.

An encrypted S3 + KMS backend with DynamoDB locking is available as an opt-in. It
adds state versioning (recover a prior version if a write goes bad), locking
(prevent concurrent applies from racing), and encryption at rest — worthwhile for
any long-lived or shared cluster, since state contains secrets (the CloudFront
`X-Origin-Verify` value and transient ECR tokens).

Enable it with one command from `infra/eks/`:

```bash
scripts/bootstrap-remote-state.sh -b <state-bucket-name> -r <aws-region>
```

This provisions the state bucket and lock table, writes `backend.hcl`, installs
`backend.tf`, and prints the `terraform init -migrate-state` command. To stay on
local state, do nothing. See [bootstrap/](./bootstrap/README.md) and
[docs/remote-state.md](./docs/remote-state.md) for the full flow and version
recovery.

---

## Quick start (no Capacity Block)

`accelerator_pools` defaults to empty, so the base cluster is Region-agnostic
and stands up without any accelerator. The two single-AZ FSx filesystems are
on by default (they bill continuously — set `fsx_enabled=false` and
`openzfs_enabled=false` for a storage-free compute-only cluster). Supply one
On-Demand GPU pool in `terraform.tfvars`:

```bash
cd infra/eks
cp terraform.tfvars.example terraform.tfvars   # set region + one pool (AZs/CIDRs auto-derive)
terraform init
terraform apply                                # ~15 min

# If you set aws_profile in terraform.tfvars, pass the SAME profile here (or
# `export AWS_PROFILE=<name>` first) — otherwise update-kubeconfig/kubectl use your
# [default] principal, which the cluster never granted access to, and you get
# "Unauthorized". Drop --profile only if [default] already IS the applying principal.
aws eks update-kubeconfig --name "$(terraform output -raw cluster_name)" \
  --region <region> --profile <same-as-tfvars>
kubectl get nodes
```

Karpenter provisions a GPU node when the first pod requesting `nvidia.com/gpu`
is scheduled.

> **"Unauthorized" from kubectl right after apply?** Two causes: (1) `kubectl`
> runs as a *different* IAM principal than the one that applied — `enable_cluster_creator_admin_permissions`
> grants admin only to the applying principal, so pass the matching `--profile`
> (above) or `export AWS_PROFILE`. Verify with `aws sts get-caller-identity` (the
> ARN must match the apply-time one). (2) Access-entry propagation lag — the admin
> access entry can take a minute or two to become effective; wait and retry.

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

# 4. Verify NCCL / EFA before the real run (see USAGE.md for the full command; GPU/EFA counts
#    come from the live node's allocatable, not a hardcoded number).
helm template exp ./charts/experiments -n $NS --set namespace=$NS \
  --set ncclSshd.enabled=true --set ncclSshd.nodeRole=<pool> \
  --set ncclSshd.gpuCount=<n> --set ncclSshd.efaCount=<n> | kubectl apply -f -
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
contiguous device IDs. See `charts/experiments` (`neuronServingVllm` workload).

> Multi-node Neuron over EFA is hardware-verified in this module (trn2.48xlarge
> x2, world_size=64 all-reduce + MNIST MLP DDP) — see
> [Known limitations](#known-limitations) and `charts/experiments`
> (`neuronDdp` workload) for the reproducible pod spec and runbook.

Two components commonly paired with GPU/Neuron inference are deliberately
**not** included — they are workload-layer concerns, not cluster infra:

- **KEDA**, for scale-to-zero autoscaling (e.g. a vLLM Deployment that scales
  Pod replicas with request rate/queue depth down to zero). Install it
  separately; its `ScaledObject` drives the Deployment, and Karpenter (this
  module) provisions the node underneath once KEDA scales past zero.
- **Mountpoint for Amazon S3 CSI driver**, for mounting model weights directly
  from S3. This module ships the two FSx layers plus EFS for shared/scratch
  storage (see above) but not an S3 mount — add the `aws-mountpoint-s3-csi-driver`
  EKS addon the same way `efs.tf` adds the EFS one, if your workload needs it.

---

## In-cluster image builder (BuildKit → ECR)

On by default (`image_builder_enabled = true`). Builds container images *inside* the
cluster with rootless BuildKit and pushes to ECR — no local docker/finch needed. This
module provisions only the **mechanism** (an ECR repo for the workshop's `ddp-sample`
image, an IAM role, a Pod Identity association, and an `image-builder` namespace +
ServiceAccount); the build itself is a catalog Job
(`charts/experiments/templates/image-build-ddp-sample.yaml`), applied with
`helm template … | kubectl apply`. See `image-builder.tf`.

The builder is a **generic mechanism, not tied to one image.** A module that consumes
this one (`source = "…/infra/eks"`) and builds a *different* image reuses the same
builder ServiceAccount by (1) creating its own ECR repository and (2) granting the
builder push to it via `image_builder_additional_ecr_repository_arns`:

```hcl
# In the consumer root module:
resource "aws_ecr_repository" "my_app" {
  name         = "${var.cluster_name}-my-app"
  force_delete = true
}

module "cluster" {
  source = "…/infra/eks"
  # …
  image_builder_additional_ecr_repository_arns = [aws_ecr_repository.my_app.arn]
}
```

The consumer owns the repo (its mutability, scanning, and lifecycle are the consumer's
call); this module only extends the builder's push permission to it. Whatever ARN you
pass gets push access verbatim, so scope it yourself — a wildcard *inside* a repository
path (`…/repository/team-*`) is fine, a bare `"*"` is rejected. The builder's identity is
surfaced for consumers that need it:

```bash
terraform output image_builder_role_arn         # for IAM audit / attaching extra policies
terraform output image_builder_namespace        # where a build Job must run
terraform output image_builder_service_account_name  # serviceAccountName for the build Job
terraform output ddp_sample_ecr_url              # the module's own ddp-sample repo URL
```

> **Design note:** `ddp_sample` is a *sample* (a "what you build"), not part of the
> mechanism, yet it currently lives in `image-builder.tf`. It predates the generic
> `image_builder_additional_ecr_repository_arns` path; ideally it would be split out and
> become just another consumer of that path. It is kept in place for backward
> compatibility (moving it would change resource addresses and force a repo re-create).

For a **large** image (pushed size in the tens of GB), turn on
`image_builder_dedicated_pool = true`: a tainted, NVMe-RAID0 Karpenter pool that Karpenter
spins up only while a build Job exists and consolidates back to zero after — so the big
local disk is billed only during the build (peak build disk ≈ pushed size × 4–5).

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
| `kubectl` / `update-kubeconfig`: `Unauthorized` | The principal `kubectl` uses differs from the one that applied (e.g. `aws_profile` set in tfvars but `update-kubeconfig` run without `--profile`, so it falls back to `[default]`); the cluster granted admin only to the applying principal | Run `update-kubeconfig` with the SAME `--profile` as `aws_profile` (or `export AWS_PROFILE`); confirm with `aws sts get-caller-identity`. If the ARNs already match, the admin access entry may still be propagating — wait a minute and retry. |
| `kubectl` acts on the wrong cluster | Multi-cluster account; context silently switched | Always check `kubectl config current-context` before operating. |
| Large accelerator image build fails: "no space left" | A small local VM disk cannot hold NGC-based images | Build on a GPU node (large NVMe) with a privileged buildkit pod, pushing straight to ECR. |
| sshd/torchrun dies (exit 143) under `kubectl exec` | Background process killed when the exec session closes | Run it as the Pod's `command:` (PID 1 subtree), not inside `exec`. |
| CPU nodes never join | Discovery tag on public subnets → Karpenter picks a no-egress subnet | Scope `karpenter.sh/discovery` to private subnets only (this module does). |
| `terraform apply`: CRD not ready | NodePool applied before the Karpenter webhook is up | `depends_on` on the CRD resources (this module does). A first apply can occasionally need a re-apply if the API is momentarily slow to serve the new types. |

---

## Cost

Rough guidance — check current pricing for your Region:

- **Always-on while the cluster exists:** EKS control plane (~$0.10/h), NAT
  gateway(s), the system managed node group, 3 Interface VPC endpoints
  (EC2/STS/SSM — ~$0.01/h each; the S3 Gateway endpoint is free), and the two
  default-on FSx filesystems (below). The endpoints exist so Karpenter keeps
  working if the NAT gateway is ever unavailable during teardown — see the
  Gotchas row on destroy ordering.
- **FSx (both layers on by default):** FSx for Lustre (`fsx_enabled = true`,
  PERSISTENT_2 SSD) and FSx for OpenZFS (`openzfs_enabled = true`,
  SINGLE_AZ_1) each bill for their full provisioned capacity continuously.
  They are on by default because the sample workloads need somewhere to write;
  set both flags to `false` for a compute-only cluster. EFS
  (`efs_enabled = true`) is off by default and bills only for what it stores.
- **Accelerators:** On-Demand GPU/Neuron nodes bill per hour while running;
  on-demand/spot pools consolidate empty nodes after a short idle by default.
  **Capacity Block** is billed upfront at purchase for the whole reserved window.

Run `terraform destroy` after a campaign to stop ongoing charges. Teardown
deletes FSx/EFS and their contents (regenerable caches) — see below.

---

## Known limitations

- **Multi-node Neuron over EFA is verified**: trn2.48xlarge x2 (Capacity Block),
  world_size=64 torch-neuronx all-reduce and the aws-neuron-samples MNIST MLP
  DDP both completed, with EFA confirmed via libfabric provider selection
  ("Opened fabric: efa-direct") and symmetric RDMA-write counter increases on
  both hosts. See `charts/experiments` (`neuronDdp` workload) for the
  reproducible pod spec, SSH/torchrun runbook, and a known driver/runtime ABI
  mismatch (`NEURON_RT_DBG_ZEROCOPY`) hit during verification.
- **Kubernetes-provider first-apply flake:** NodePool/EC2NodeClass occasionally
  need a second `apply` if the Karpenter CRDs are not yet Established.
- **CRD upgrades:** the `karpenter-crd` chart is installed separately so CRDs
  track the chart version; still review CRD changes when bumping versions.
- **Terraform state contains secrets** (the CloudFront `X-Origin-Verify` value,
  transient ECR tokens). Use the opt-in encrypted S3 + KMS backend for any
  long-lived or shared cluster (see [State management](#state-management)).
- **Teardown deletes data:** FSx/EFS have no `prevent_destroy` (so the
  environment is disposable). Set it, or back up, before storing anything you
  cannot regenerate.
- The `data.http` fetch for the ALB Controller IAM policy is a plan-time network
  dependency; the Training Operator manifest is vendored (committed) to avoid one.
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
