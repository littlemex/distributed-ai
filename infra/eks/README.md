# EKS + Capacity Block — Distributed Training Infrastructure

Production-grade EKS cluster with Karpenter-managed Capacity Block nodes
for multi-node GPU training on p5en/p5 (H200/H100) instances with EFA.

---

## Overview

This module provisions:

- An EKS 1.35 cluster (us-east-2) with a small system node group (m5-series).
- Karpenter v1.13.0 to schedule workloads onto Capacity Block reservations.
- AWS EFA device plugin (v0.5.29) so each p5en node exposes 16 EFA slots.
- Optional FSx for Lustre CSI driver for shared model checkpoints.
- Helm-based addon lifecycle (EFA plugin, FSx CSI, Karpenter) managed by Terraform.

The cluster is purpose-built for batch distributed training runs tied to a
Capacity Block reservation. It is not intended as a general-purpose long-lived
cluster; tear it down after each training campaign.

---

## Architecture

```
┌─ VPC (us-east-2) ──────────────────────────────────────────────────────┐
│                                                                         │
│  ┌── EKS Control Plane ──────────────────────────────────────────────┐ │
│  │  kubernetes 1.35                                                  │ │
│  │  IRSA / Pod Identity  ·  aws-auth ConfigMap                       │ │
│  └───────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│  ┌── System node group (m5.xlarge × 2) ─────────────────────────────┐ │
│  │  kube-system workloads, Karpenter controller                      │ │
│  └───────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│  ┌── Capacity Block nodes (p5en.48xlarge, single AZ) ───────────────┐ │
│  │  8 × H200 GPU  ·  16 × EFA NIC  ·  hostNetwork pods             │ │
│  │  Provisioned by Karpenter NodePool  capacity-type=reserved        │ │
│  │  Bound to EC2NodeClass.spec.capacityReservationSelectorTerms      │ │
│  └───────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│  EFA fabric (intra-AZ, GPUDirect RDMA)  ←→  ~514 GB/s busbw          │
│  FSx for Lustre (optional)              ←→  shared checkpoints         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Why EKS + Capacity Block + EFA

| Concern | Choice | Rationale |
|---|---|---|
| **Guaranteed capacity** | Capacity Block (CB) | H200/H100 nodes are not available on-demand; CB reserves capacity for a fixed window at a fixed price. |
| **Node lifecycle** | Karpenter NodePool | Karpenter binds the NodePool to the CB reservation and applies the `reserved` capacity-type so nodes start as soon as the reservation is active. |
| **Interconnect** | EFA (Elastic Fabric Adapter) | EFA delivers ~514 GB/s all-reduce busbw across nodes via GPUDirect RDMA — required for efficient multi-node training at this scale. |
| **Orchestration** | EKS | Portable manifest format; reuses ADT nccl-tests/MPIJob recipes verbatim; no proprietary control plane lock-in. |

---

## Why Terraform (not CDK / eksctl)

Karpenter v1.13.0 changed several Helm values and CRD fields in ways that
break CDK constructs and eksctl add-on shims:

1. **Helm values generation gap** — CDK's `@aws-cdk/aws-eks` constructs
   generate Karpenter Helm values using cached field names from an older chart
   version. The `v1.13` chart moved `featureGates` nesting and dropped the
   top-level `settings.aws` block. Deploying via CDK silently ignores the new
   keys, leaving `ReservedCapacity` unconfigured (it is enabled by default in
   v1.13, but the mismatch causes confusion and drift).

2. **capacity-type label** — eksctl's `managed-nodegroup` and some CDK
   patterns stamp Karpenter nodes with `capacity-type=capacity-block`.
   Karpenter provider-aws v1.13.0 expects `karpenter.sh/capacity-type=reserved`
   (confirmed by `kubectl get nodeclaim -o yaml`). Using the wrong value means
   the NodePool requirement selector never matches and no node is provisioned.

3. **kubectl provider for CRDs** — EC2NodeClass and NodePool are applied as
   Kubernetes CRDs after the Helm chart installs. Terraform's
   `gavinbunney/kubectl` provider handles this cleanly with `wait = true`
   dependencies. CDK requires a custom resource Lambda with a race condition on
   CRD readiness; eksctl cannot apply arbitrary CRDs at all.

4. **Explicit dependency graph** — `terraform apply` serialises
   `module.eks → helm_release.karpenter → kubectl_manifest.nodeclass →
   kubectl_manifest.nodepool`, ensuring Karpenter is ready before CRDs are
   applied. CDK achieves this only with manual `node.addDependency` chains
   that are easy to miss.

Terraform gives a single, auditable plan for every change, and the
`terraform-aws-eks` module (v21.24.0) generates correct aws-auth and IRSA
bindings out of the box.

---

## Prerequisites

| Tool | Minimum version |
|---|---|
| Terraform | 1.9+ |
| AWS CLI | 2.15+ |
| kubectl | 1.29+ |
| helm | 3.14+ |
| python3 | 3.10+ (scripts use it for JSON parsing) |

AWS credentials:

```bash
# Verify identity before running anything
aws sts get-caller-identity   # confirm your account/region
# Expected: your AWS account, region us-east-2
```

Sufficient IAM permissions: `AmazonEKSClusterPolicy`, `AmazonEC2FullAccess`
(for CB operations), `IAMFullAccess` (for IRSA roles).

---

## Step-by-step

### 1. Bootstrap cluster

```bash
cd infra/eks
cp terraform.tfvars.example terraform.tfvars.local   # fill in your values
terraform init
terraform plan  -var-file=terraform.tfvars.local
terraform apply -var-file=terraform.tfvars.local     # ~15 min
```

Update kubeconfig:

```bash
aws eks update-kubeconfig \
  --name <cluster-name> \
  --region us-east-2 \
  --profile "$AWS_PROFILE"
kubectl get nodes   # system nodes visible
```

### 2. Install addons

```bash
# EFA device plugin and FSx CSI are applied via Terraform helm_release blocks.
# Verify after apply:
kubectl -n kube-system get pods -l app=aws-efa-k8s-device-plugin
kubectl -n kube-system get pods -l app=fsx-csi-node
```

### 3. Gate — confirm no GPU workloads running

```bash
kubectl get pods -A -o json \
  | python3 -c "
import sys, json
pods = json.load(sys.stdin)['items']
gpu = [p['metadata']['namespace']+'/'+p['metadata']['name']
       for p in pods
       if p.get('status',{}).get('phase')=='Running'
       and any(int(c.get('resources',{}).get('requests',{}).get('nvidia.com/gpu',0))>0
               for c in p.get('spec',{}).get('containers',[]))]
print('GPU pods:', gpu or 'none')
"
```

### 4. Check Capacity Block offerings

```bash
./scripts/00-check-cb-offerings.sh
# Adjust --duration-hours to match your training window.
# Note the CapacityBlockOfferingId and AvailabilityZone.
```

### 5. Purchase Capacity Block (requires explicit budget approval)

```bash
# Review the price shown, then confirm at the prompt.
./scripts/01-purchase-cb.sh \
  --offering-id <CapacityBlockOfferingId> \
  --instance-type p5en.48xlarge \
  --instance-count 2
```

The script prints the `CapacityReservationId` (`cr-…`) and `EndDate`.

### 6. Write CR-ID to tfvars and apply NodePool

```bash
./scripts/02-post-purchase.sh \
  --cr-id cr-0123456789abcdef0 \
  --end-date 2026-07-11T12:00:00Z

terraform apply -var-file=terraform.tfvars.local
# NodePool and EC2NodeClass are created; Karpenter provisions CB nodes.
kubectl get nodes -l karpenter.sh/capacity-type=reserved   # nodes appear
```

### 7. Verify NCCL / EFA

```bash
./scripts/03-verify-nccl.sh \
  --namespace my-ns \
  --image <ACCOUNT_ID>.dkr.ecr.us-east-2.amazonaws.com/nccl-tests:latest \
  --nodes 2 \
  --gpus-per-node 8
# Expect busbw ≥ 400 GB/s at 1 GB message size.
# Confirm log line: "NET/OFI Selected provider is efa"
```

### 8. Run training workload

Submit your MPIJob or torchrun manifest. See `manifests/` for reference
templates. Key requirements:

- `hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet`
- `tolerations` for `capacity-reservation` with `operator: Exists`
- `NCCL_SOCKET_IFNAME=^lo,docker,veth` (exclusion pattern — do not use a positive list)
- `FI_PROVIDER=efa`, `FI_EFA_USE_DEVICE_RDMA=1`, `FI_EFA_FORK_SAFE=1`

### 9. Teardown

```bash
# Remove workloads and NodePool only (cluster stays):
./scripts/04-teardown.sh --namespace my-ns

# Full destroy (removes EKS cluster):
./scripts/04-teardown.sh --namespace my-ns --destroy
```

---

## Cost note

| Item | Approximate cost |
|---|---|
| p5en.48xlarge × 2, 24 h Capacity Block | ~$2,636 USD |
| p5.48xlarge × 2, 24 h Capacity Block | ~$1,758 USD (H100) |
| EKS control plane | $0.10/h → ~$2.40/24 h |
| m5.xlarge system nodes × 2 | ~$0.38/24 h |

Capacity Block charges are upfront at purchase time.
The cluster EC2/EKS costs accrue while the cluster is running.
Destroy the cluster after the training campaign to stop ongoing charges.

---

## Gotcha table

Confirmed through direct measurement and cluster inspection.

| Symptom | Root cause | Fix |
|---|---|---|
| Karpenter never provisions nodes | `capacity-type=capacity-block` in NodePool requirements | Use `karpenter.sh/capacity-type In [reserved]` (v1.13 label value) |
| CB nodes not matched by NodePool | `EC2NodeClass.spec.capacityReservationSelectorTerms` missing or wrong | Set `[{id: cr-<hex>}]` exactly as returned by purchase API |
| `featureGates.reservedCapacity` rejected by Helm | Field not exposed in v1.13 chart values | Remove it — `ReservedCapacity=true` is the compiled default; explicit setting causes unknown-key error |
| NCCL falls back to TCP, 28× slower | Positive `NCCL_SOCKET_IFNAME` hides EFA interfaces | Use exclusion pattern: `NCCL_SOCKET_IFNAME=^lo,docker,veth` |
| `fi_info -p efa` returns empty | Pod missing `vpc.amazonaws.com/efa` resource request | Add `limits: {vpc.amazonaws.com/efa: "16"}` and the EFA toleration |
| sshd/torchrun dies (exit 143) in `kubectl exec` | Background process killed on exec session close (SIGTERM) | Run sshd or torchrun as `command:` in the pod spec (PID 1 subtree) |
| EFA device plugin chart version confusion | Chart `v0.5.29` ships app version `v0.5.20`; do not mix them | Use chart version `v0.5.29` — do not substitute app version |
| `expireAfter` rejected by NodePool | ISO 8601 duration not supported | Use Go duration string, e.g. `"24h"` |
| Observation pod gets `UnexpectedAdmissionError` | Requested `vpc.amazonaws.com/efa` but training pod holds all 16 | Observation pods read EFA counters via netlink — request no EFA resource |
| `terraform apply` fails: CRD not ready | NodePool/EC2NodeClass applied before Karpenter webhook is up | Add `depends_on = [helm_release.karpenter]` in kubectl provider resources |
| CDK Karpenter deploy silently misconfigured | CDK generates v0.x-era Helm values; v1.13 chart ignores unknown keys | Use Terraform with explicit `values = [yamlencode({...})]` |
