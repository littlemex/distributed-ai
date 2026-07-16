# Usage Guide

A task-oriented walkthrough for operating this EKS + accelerator environment.
The [README](./README.md) is the reference (every variable, every design
decision); this guide is the "how do I actually do X" companion. All commands
are copy-paste ready — replace `<angle-bracket>` placeholders with your values.

**Conventions**

- `$` lines are shell commands you run from `infra/eks/`.
- Nothing here contains account IDs, cluster names, or IPs — set your own in
  `terraform.tfvars`.
- If you use a named AWS profile, either `export AWS_PROFILE=<name>` once or add
  `aws_profile = "<name>"` to `terraform.tfvars`.

---

## 1. First-time setup

You need Terraform 1.9+, AWS CLI 2.15+, kubectl 1.29+, and helm 3.14+. Confirm
you are pointed at the right AWS account **before** creating anything:

```bash
$ aws sts get-caller-identity          # is this the account you meant?
$ cd infra/eks
$ cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and set at least `region`, `azs`, `cluster_name`, and
one entry in `accelerator_pools`. The smallest useful starting point is a single
On-Demand GPU pool:

```hcl
accelerator_pools = {
  gpu-dev = {
    instance_types = ["g5.12xlarge"]   # A10G x4, no Capacity Block needed
    device_plugin  = "nvidia"
    capacity_type  = "on-demand"
    zone           = "us-east-2a"
  }
}
```

Then bring the cluster up:

```bash
$ terraform init
$ terraform apply                      # ~15 minutes for the control plane + system nodes
$ aws eks update-kubeconfig --name "$(terraform output -raw cluster_name)" --region <region>
$ kubectl get nodes                    # you should see the system nodes
```

No GPU node exists yet — Karpenter creates one on demand (next section).

> **Always verify your kubectl context** before running cluster commands,
> especially if your account has more than one cluster:
> ```bash
> $ kubectl config current-context     # must be YOUR cluster
> ```

---

## 2. Run something on a GPU

Karpenter provisions a GPU node the moment a Pod requests `nvidia.com/gpu`.
Try it with a one-shot CUDA check:

```bash
$ kubectl run gpu-smoke --rm -it --restart=Never \
    --image=nvidia/cuda:12.4.1-base-ubuntu22.04 \
    --overrides='{"spec":{"tolerations":[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]}}' \
    -- nvidia-smi
```

The first run takes a few minutes while Karpenter launches the node and the GPU
Operator advertises `nvidia.com/gpu`. Watch it happen:

```bash
$ kubectl get nodeclaims -w           # a gpu-dev claim appears, then Ready
$ kubectl get nodes -l karpenter.sh/nodepool=gpu-dev
```

When the Pod finishes, Karpenter scales the empty GPU node back down after the
idle window (5 minutes by default for on-demand/spot pools).

---

## 3. How much EFA can a Pod request?

For pools on EFA-capable instances (p5/p5en/trn2), **do not guess** the EFA
count — the module computes the schedulable value for you:

```bash
$ terraform output accelerator_pool_efa_schedulable
# {
#   "gpu-p5en" = 15     # 16 network cards, but card 0 carries the node IP
# }
```

Request that number in your Pod (never more, or it will never schedule):

```yaml
resources:
  limits:
    nvidia.com/gpu: 8
    vpc.amazonaws.com/efa: 15
```

Also add the accelerator toleration and the NCCL/EFA environment your framework
expects (see the multi-node example in `manifests/`).

---

## 4. Use a Capacity Block (H200 / H100 / Trainium)

Capacity Blocks reserve scarce accelerator capacity for a fixed window. The
workflow:

```bash
# a. See what is offered for your instance type, duration, and AZ.
$ ./scripts/00-check-cb-offerings.sh

# b. Purchase it (prints the price and asks to confirm — needs budget approval).
$ ./scripts/01-purchase-cb.sh --offering-id <id> --instance-type p5en.48xlarge --instance-count 2

# c. Turn the reservation into a pool block you can paste into terraform.tfvars.
$ ./scripts/02-post-purchase.sh --cr-id cr-<hex> --end-date <RFC3339> \
      --instance-type p5en.48xlarge --zone <az> --pool gpu-p5en
```

Paste the printed block into `accelerator_pools`, then:

```bash
$ terraform apply
$ kubectl get nodes -l karpenter.sh/capacity-type=reserved   # CB node appears
```

Set `cb_end_date` on the pool to get an SNS alert one hour before the
reservation expires (subscribe an email via `cb_alert_email_addresses`). When
the block ends, AWS reclaims the node — drain your workload before then.

Verify the fabric before a real multi-node run:

```bash
$ ./scripts/03-verify-nccl.sh --nodes 2 --gpus-per-node 8
# Look for a high busbw and "NET/OFI Selected provider is efa" in the logs.
```

---

## 5. Run on Trainium / Inferentia (Neuron)

Add a pool with `device_plugin = "neuron"` and the Neuron AMI:

```hcl
trn2 = {
  instance_types    = ["trn2.48xlarge"]
  device_plugin     = "neuron"
  capacity_type     = "reserved"
  zone              = "us-east-2b"
  cb_reservation_id = "cr-<hex>"
  ami_ssm_parameter = "/aws/service/eks/optimized-ami/1.35/amazon-linux-2023/x86_64/neuron/recommended/image_id"
}
```

Pods request whole devices with `aws.amazon.com/neuron: "<n>"`. For
tensor-parallel serving across many chips, set `neuron_enable_scheduler = true`
so device IDs are allocated contiguously. See
`manifests/neuron-serving-vllm.yaml.tpl`.

---

## 6. Shared storage

- **EFS** (`efs_enabled = true`, on by default): multi-AZ, ReadWriteMany. Ideal
  for a compiled-model / Hugging Face cache that must survive a Pod reschedule
  when Karpenter replaces a node. A static PV named `efs-neuron-workspace` is
  created for you.
- **FSx for Lustre** (`fsx_enabled = true`, off by default): single-AZ,
  high-throughput scratch/checkpoints. It bills for the full provisioned
  capacity continuously — enable it only for runs that need it.

---

## 7. Expose a service to the internet (demo)

A CloudFront → ALB → EKS path is included as a sample. It is a **two-phase**
apply because the ALB must exist before CloudFront can point at it:

```bash
$ terraform apply                              # phase 1: creates the ALB
$ terraform apply -var enable_cloudfront=true  # phase 2: CloudFront + SG lock-down
$ terraform output cloudfront_domain_name
```

This is a demo, not a production endpoint — see "Production hardening" in the
README before relying on it.

---

## 8. Tear it down

Stop paying for the cluster when you are done:

```bash
$ ./scripts/04-teardown.sh            # drain the accelerator pools (keep the cluster)
$ ./scripts/04-teardown.sh --destroy  # destroy everything
```

If `terraform destroy` stalls on a subnet that "has dependencies", it is almost
always a leftover ENI from a Karpenter node or a load balancer that Terraform
does not manage. Delete those first:

```bash
$ kubectl delete nodepool --all       # Karpenter drains its nodes
$ kubectl delete ingress --all -A     # removes ALBs created by the LB controller
# wait a minute for the ALB/ENIs to disappear, then re-run destroy
```

> **Teardown deletes data.** FSx and EFS are created without `prevent_destroy`
> so the environment is disposable. Back up anything you cannot regenerate
> first.

---

## 9. Troubleshooting quick reference

| You see… | Do this |
|---|---|
| GPU Pod stays `Pending`, "no instance type has enough resources" | You probably requested more EFA than schedulable — check `terraform output accelerator_pool_efa_schedulable` and request ≤ that. |
| Karpenter never launches a reserved node | The Capacity Block slot may not be free yet (previous instance still terminating), or `cb_reservation_id` is wrong. Confirm the reservation is `active`. |
| GPU Pod runs but `nvidia-smi` shows nothing | The GPU Operator may still be initializing on a fresh node; give it 2–3 minutes and check `kubectl -n gpu-operator get pods`. |
| NCCL is slow / not using EFA | Set `NCCL_SOCKET_IFNAME=^lo,docker,veth` (exclusion pattern) and confirm `FI_PROVIDER=efa`; look for `NET/OFI Selected provider is efa` in logs. |
| `kubectl` commands hit the wrong cluster | `kubectl config current-context` — run `aws eks update-kubeconfig` for the intended cluster. |
| Hugging Face downloads fail with `429` | Your egress IP is rate-limited. Set `HF_HUB_DISABLE_XET=1`, and for multi-rank jobs pre-stage the tokenizer/dataset to shared storage and load from the local path. |
| `terraform apply` fails once on a Karpenter CRD, succeeds on retry | Known first-apply timing with the Kubernetes provider; just re-run `terraform apply`. |

For the full list of subtle failure modes and their root causes, see the
**Gotchas** section of the [README](./README.md#gotchas).
