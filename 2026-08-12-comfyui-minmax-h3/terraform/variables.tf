################################################################################
# Root-module inputs.
#
# This root wraps the reusable ../../infra/eks module and adds one GPU pool sized
# for ComfyUI + MiniMax-H3. Every value below is a knob — nothing about the region,
# account, instance type, or model is hardcoded downstream. The defaults describe a
# single-GPU L40S serving pool, but each can be overridden in terraform.tfvars.
################################################################################

# ── Where + who ───────────────────────────────────────────────────────────────

variable "region" {
  description = "AWS region for the cluster. us-west-2 by default (the target for this project); the base module derives every AZ and subnet from it."
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "EKS cluster name. Must be unique per account+region so it never collides with the base infra/eks cluster (distai-eks-smoke in us-east-2)."
  type        = string
  default     = "comfyui-minimax-h3"
}

variable "aws_profile" {
  description = <<-EOT
    Named AWS CLI/Terraform profile, threaded to this root's aws provider AND down
    into the cluster module (its aws/helm/kubectl providers + CLI helpers). Set it
    whenever you authenticate via a named profile (SSO/Isengard/assume-role); leave
    null only when the default credential chain already resolves to the intended
    principal. Use the SAME profile for `aws eks update-kubeconfig` or kubectl gets
    Unauthorized (the cluster grants admin only to the applying principal).
  EOT
  type        = string
  default     = null
}

variable "expected_account_id" {
  description = "Guardrail: when set to a 12-digit account ID, the plan fails if the resolved credentials point at a different account. Strongly recommended so a profile mix-up cannot stand this cluster up in the wrong account."
  type        = string
  default     = null

  validation {
    condition     = var.expected_account_id == null || can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "expected_account_id must be a 12-digit AWS account ID (or null to skip the check)."
  }
}

variable "environment" {
  description = "Deployment environment label used in resource tags."
  type        = string
  default     = "dev"
}

variable "tags" {
  description = "Common tags applied to all resources (this root's ECR/IAM and, passed through, the cluster module's resources)."
  type        = map(string)
  default = {
    Project   = "distributed-ai"
    Workload  = "comfyui-minimax-h3"
    ManagedBy = "terraform"
  }
}

# ── ComfyUI GPU pool ────────────────────────────────────────────────────────────

variable "gpu_pool_name" {
  description = <<-EOT
    Karpenter NodePool key for the ComfyUI GPU pool. Becomes the node-role label
    (node-role=<this>) that the ComfyUI workload's nodeSelector targets, so it must
    match charts/comfyui values comfyui.nodeRole. RFC1123.
  EOT
  type        = string
  default     = "comfyui"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.gpu_pool_name))
    error_message = "gpu_pool_name must be RFC1123 (lowercase alphanumeric and '-', start/end alphanumeric) — it becomes a Kubernetes resource name and label."
  }
}

variable "gpu_instance_types" {
  description = <<-EOT
    EC2 GPU instance types Karpenter may launch for the ComfyUI pool, in preference
    order (Karpenter tries them all for capacity flexibility). Default is a single
    L40S (48 GB VRAM, 64 GB host RAM) plus a larger-RAM fallback — MiniMax-H3's
    ~40 GB of weights load into 48 GB VRAM with ComfyUI's sequential offload, and the
    text encoder benefits from host RAM headroom. All types here share one EFA
    topology (g6e single-GPU sizes have no EFA — derived to 0), which the base module
    validates. Do NOT add 24 GB cards (g6/g5.*) here: a 33B video model is unreliable
    on 24 GB. If you want a cheap 24 GB experiment pool, add it as a SEPARATE pool
    (extra_accelerator_pools) rather than mixing it into the serving path.
  EOT
  type        = list(string)
  default     = ["g6e.2xlarge", "g6e.4xlarge"]

  validation {
    condition     = length(var.gpu_instance_types) > 0
    error_message = "gpu_instance_types must list at least one instance type."
  }
}

variable "gpu_capacity_types" {
  description = <<-EOT
    Karpenter capacity types for the ComfyUI pool, in Karpenter's native priority
    order (reserved -> spot -> on-demand). Default ["on-demand"] because ComfyUI is a
    STATEFUL single pod: its queue is in-memory, so a Spot reclaim mid-generation
    loses the in-flight job and forces a multi-minute model reload. For a
    cost-optimised, interruption-tolerant experiment you may set ["spot","on-demand"]
    (Spot preferred, On-Demand fallback), but pair it with a client that retries.
  EOT
  type        = list(string)
  default     = ["on-demand"]

  validation {
    condition = length(var.gpu_capacity_types) > 0 && alltrue([
      for ct in var.gpu_capacity_types : contains(["reserved", "on-demand", "spot"], ct)
    ])
    error_message = "gpu_capacity_types must be a non-empty subset of [\"reserved\",\"on-demand\",\"spot\"]."
  }
}

variable "gpu_node_volume_size" {
  description = <<-EOT
    Root EBS size for ComfyUI GPU nodes. The CUDA + PyTorch + ComfyUI image is
    15-20 GB and the ~40 GB of MiniMax-H3 weights land on the shared filesystem (not
    the root disk), but a generous root avoids DiskPressure eviction during image
    pull + any local temp. 200Gi is a safe default; lower only on a cost-sensitive run.
  EOT
  type        = string
  default     = "200Gi"
}

variable "gpu_pool_disruption" {
  description = <<-EOT
    Karpenter disruption preset for the ComfyUI pool: \"protect\" (never voluntarily
    disrupt a running node — WhenEmpty + consolidateAfter Never + budget 0) or
    \"reclaim\" (reclaim idle nodes). Default \"protect\": consolidation would happily
    evict a single stateful ComfyUI pod mid-generation even on On-Demand. The pod ALSO
    carries karpenter.sh/do-not-disrupt (set in charts/comfyui) as belt-and-suspenders.
    Use \"reclaim\" only for a throwaway pool you want auto-scaled to zero when idle.
  EOT
  type        = string
  default     = "protect"

  validation {
    condition     = contains(["protect", "reclaim"], var.gpu_pool_disruption)
    error_message = "gpu_pool_disruption must be \"protect\" or \"reclaim\"."
  }
}

variable "gpu_pool_termination_grace_period" {
  description = <<-EOT
    NodePool terminationGracePeriod (Go duration) — the upper bound on a node's graceful drain.
    Because the ComfyUI pod uses karpenter.sh/do-not-disrupt, a `terraform destroy` could
    otherwise hang on the NodeClaim finalizer waiting for a pod that refuses eviction. This caps
    that wait so destroy always completes. 10m leaves room for a graceful ComfyUI shutdown.
  EOT
  type        = string
  default     = "10m"
}

variable "gpu_pool_zone" {
  description = <<-EOT
    Single AZ to pin the ComfyUI pool to. Leave \"\" (default) to derive the first
    cluster AZ (local.azs[0]), which is ALSO where the default FSx/OpenZFS filesystems
    live (subnet_index 0) — so compute and the model/output storage stay co-located in
    one AZ and never pay cross-AZ NFS. Set an explicit AZ only to override; it must be
    one of the region's AZs and should match storage_subnet_index's AZ.
  EOT
  type        = string
  default     = ""
}

variable "extra_accelerator_pools" {
  description = <<-EOT
    Escape hatch: additional accelerator pools merged alongside the ComfyUI pool and
    passed straight into the base module's accelerator_pools. Use this for a separate
    24 GB experiment pool, a Capacity Block pool, etc. — WITHOUT touching the serving
    pool. The object shape is the base module's accelerator_pools value type; see
    ../../infra/eks/variables.tf for every field. Empty by default.
  EOT
  type        = any
  default     = {}
}

# ── Storage ───────────────────────────────────────────────────────────────────

variable "storage_subnet_index" {
  description = <<-EOT
    Index into the resolved AZ list for the single-AZ FSx OpenZFS filesystem that
    holds the model weights and outputs. 0 = the first cluster AZ, which is also where
    an unpinned GPU pool lands — keep this aligned with gpu_pool_zone so ComfyUI reads
    weights from a same-AZ filesystem (no cross-AZ NFS cost/latency).
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.storage_subnet_index >= 0
    error_message = "storage_subnet_index must be >= 0."
  }
}

variable "openzfs_storage_capacity_gib" {
  description = <<-EOT
    FSx OpenZFS capacity (GiB) for the /shared model + output layer. MiniMax-H3's four
    weight files total ~40 GB; 256 GiB leaves ample room for outputs and a second model
    revision. Minimum 64.
  EOT
  type        = number
  default     = 256

  validation {
    condition     = var.openzfs_storage_capacity_gib >= 64
    error_message = "openzfs_storage_capacity_gib must be at least 64 (FSx OpenZFS minimum)."
  }
}

variable "openzfs_throughput_capacity" {
  description = "FSx OpenZFS throughput (MB/s). 256 loads the ~40 GB of weights in a couple of minutes. Valid SINGLE_AZ_1 values: 64/128/256/512/1024/2048/3072/4096."
  type        = number
  default     = 256
}

variable "fsx_lustre_enabled" {
  description = <<-EOT
    Whether to also create the FSx for Lustre scratch filesystem (base module default
    is ON). OFF here: a single-model, single-node ComfyUI smoke has nothing that needs
    a high-throughput parallel scratch, and Lustre bills continuously. The OpenZFS NFS
    layer alone holds weights + outputs. Turn this on only if a workload needs Lustre.
  EOT
  type        = bool
  default     = false
}

# ── ComfyUI image (ECR) ─────────────────────────────────────────────────────────

variable "comfyui_image_repository_name" {
  description = <<-EOT
    ECR repository name for the ComfyUI image built in-cluster. Leave null to derive
    \"<cluster_name>-comfyui\". ECR repo names are unique per account+region, so the
    cluster_name prefix prevents a collision with a second cluster in the same account.
  EOT
  type        = string
  default     = null
}
