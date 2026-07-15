variable "region" {
  description = "AWS region where the cluster is deployed."
  type        = string
  default     = "us-east-2"
}

variable "azs" {
  description = <<-EOT
    Availability zones for the VPC and EKS control plane. EKS requires subnets in
    at least two AZs. GPU nodes are pinned to a single AZ via var.gpu_zone (which
    must be one of these) so that Capacity Block placement (single-AZ) is honored
    while the control plane still spans multiple AZs.
  EOT
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b"]
}

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
  default     = "distai-eks"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster. Verified available: 1.35. (terraform-aws-eks v21.24.0 uses 'kubernetes_version', not 'cluster_version'.)"
  type        = string
  default     = "1.35"
}

# ── Accelerator NodePools ─────────────────────────────────────────────────────
# Single source of truth for every accelerated Karpenter NodePool + EC2NodeClass.
# One map entry == one pool. GPU (NVIDIA) and Trainium/Inferentia (Neuron) pools are
# described uniformly; karpenter-resources.tf renders them with for_each, and the
# device-plugin add-ons key off the `device_plugin` field. Add a pool by adding a map
# entry — no new resource blocks required.
#
# Field reference:
#   instance_type        EC2 instance type (e.g. "g6e.12xlarge", "trn2.48xlarge", "p5en.48xlarge").
#   device_plugin        "nvidia" | "neuron" — selects which device-plugin add-on advertises
#                        the accelerator and which resource name pods request
#                        (nvidia.com/gpu vs aws.amazon.com/neuron).
#   capacity_type        "reserved" (Capacity Block) | "on-demand" | "spot".
#   zone                 Single AZ to pin the pool to (must be one of var.azs). Capacity Block
#                        is single-AZ; this also pins on-demand/spot pools for locality.
#   efa_interface_count  Max EFA interfaces for the instance (g6e=1, p5en=16, p5=32, trn2=16).
#                        0 disables EFA.
#   efa_multi_card       false = all EFA interfaces on network card 0 (single-card, e.g. g6e).
#                        true  = one EFA interface per network card (multi-card: p5/p5en/trn2).
#   ami_alias            Karpenter amiSelectorTerms alias, e.g. "al2023@latest". Used when
#                        ami_ssm_parameter is empty. For Neuron instances the AL2023 alias
#                        resolves to the Neuron AMI variant.
#   ami_ssm_parameter    Optional SSM parameter path for a pinned AMI id. When non-empty it
#                        overrides ami_alias (use for deterministic Neuron/GPU AMI selection).
#   cb_reservation_id    Capacity Block reservation id (cr-...) for capacity_type "reserved".
#                        Empty otherwise; the selector term is omitted for on-demand/spot.
#   volume_size          Root EBS volume size (e.g. "200Gi").
#   expire_after         Karpenter NodePool expireAfter ("Never" or a Go duration).
#   cpu_limit / memory_limit  Karpenter NodePool spec.limits caps.
variable "accelerator_pools" {
  description = "Map of accelerated Karpenter NodePools (GPU and/or Neuron). See the field reference above."
  type = map(object({
    instance_type       = string
    device_plugin       = string           # "nvidia" | "neuron"
    capacity_type       = string           # "reserved" | "on-demand" | "spot"
    zone                = string
    efa_interface_count = number
    efa_multi_card      = bool
    ami_alias           = optional(string, "al2023@latest")
    ami_ssm_parameter   = optional(string, "")
    cb_reservation_id   = optional(string, "")
    volume_size         = optional(string, "200Gi")
    expire_after        = optional(string, "Never")
    cpu_limit           = optional(string, "10000")
    memory_limit        = optional(string, "100000Gi")
  }))
  default = {
    # GPU smoke-test pool: g6e.12xlarge (L40S x4, single-card EFA x1). Verified.
    gpu-training = {
      instance_type       = "g6e.12xlarge"
      device_plugin       = "nvidia"
      capacity_type       = "on-demand"
      zone                = "us-east-2b"
      efa_interface_count = 1
      efa_multi_card      = false
    }
  }
  validation {
    condition     = alltrue([for k, p in var.accelerator_pools : contains(["nvidia", "neuron"], p.device_plugin)])
    error_message = "Each accelerator pool's device_plugin must be \"nvidia\" or \"neuron\"."
  }
  validation {
    condition     = alltrue([for k, p in var.accelerator_pools : contains(["reserved", "on-demand", "spot"], p.capacity_type)])
    error_message = "Each accelerator pool's capacity_type must be \"reserved\", \"on-demand\", or \"spot\"."
  }
  validation {
    condition     = alltrue([for k, p in var.accelerator_pools : contains(var.azs, p.zone)])
    error_message = "Each accelerator pool's zone must be one of the AZs listed in var.azs."
  }
  validation {
    condition     = alltrue([for k, p in var.accelerator_pools : p.capacity_type != "reserved" || p.cb_reservation_id != ""])
    error_message = "A pool with capacity_type \"reserved\" must set cb_reservation_id (cr-...)."
  }
}

variable "cpu_nodepool_enabled" {
  description = "Create a CPU-only Karpenter NodePool (on-demand) for non-GPU workloads and controllers."
  type        = bool
  default     = true
}

variable "cpu_instance_categories" {
  description = "Instance categories Karpenter may use for the CPU NodePool (Karpenter well-known key karpenter.k8s.aws/instance-category)."
  type        = list(string)
  default     = ["c", "m", "r"]
}

variable "cb_reservation_id" {
  description = "Capacity Block reservation ID (cr-xxx) obtained from purchase-capacity-block. Empty string disables CB NodePool."
  type        = string
  default     = ""
}

variable "cb_end_date" {
  description = <<-EOT
    Expiry datetime of the Capacity Block in RFC3339 format (e.g. 2024-12-31T23:59:59Z).
    Used by eventbridge-cb-alarm.tf to schedule a one-shot SNS alert 1 hour before the
    reservation ends. (Node lifetime is controlled per pool by accelerator_pools[*].expire_after.)
    Leave empty when no Capacity Block is purchased.
  EOT
  type        = string
  default     = ""
}

variable "aws_profile" {
  description = "AWS CLI/Terraform provider profile name."
  type        = string
  default     = "default" # AWS named profile for authentication
}

variable "vpc_cidr" {
  description = <<-EOT
    CIDR block for the VPC. /16 (65,536 addresses) because accelerated ML nodes consume IPs
    heavily: the VPC CNI assigns many secondary IPs per node, and multi-card EFA instances
    (trn2.48xlarge = 16 EFA-only ENIs, p5en = 16, p5 = 32) each consume an IP per ENI. A /21
    or /24 exhausts almost immediately and leaves the EKS control plane unable to place its
    management ENIs (cluster goes IMPAIRED / InsufficientFreeAddresses). AWS's own
    awsome-distributed-ai HyperPod-EKS reference sizes private subnets at /16 each.
  EOT
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = <<-EOT
    CIDR blocks for private subnets (one per AZ). Node workloads run here, so these are made
    as large as the VPC allows: /17 = 32,768 addresses per subnet. This mirrors AWS's
    awsome-distributed-ai HyperPod-EKS reference, which sizes private subnets at /16 each
    (its VPC is 10.192.0.0/16 with tiny /24 public subnets) — the design principle is
    "public small, private huge" because every GPU/Neuron node holds dozens of Pod ENIs
    plus EFA-only ENIs. Do NOT use /24 — a single trn2/p5 node's ENIs can exhaust it.
  EOT
  type        = list(string)
  default     = ["10.0.0.0/18", "10.0.64.0/18"]
}

variable "public_subnet_cidrs" {
  description = <<-EOT
    CIDR blocks for public subnets (one per AZ). NAT gateways and load balancers only, so
    these are kept small (/24 = 251 usable), matching the awsome-distributed-ai reference
    (10.192.10.0/24, 10.192.11.0/24). Carved from the top of the VPC so they do not eat into
    the large private ranges.
  EOT
  type        = list(string)
  default     = ["10.0.254.0/24", "10.0.255.0/24"]
}

variable "environment" {
  description = "Deployment environment label (e.g. dev, staging, prod). Used in resource tags."
  type        = string
  default     = "dev"
}

variable "gpu_operator_install_driver" {
  description = "Whether the NVIDIA GPU Operator should install the GPU driver. Set false when the EKS AMI already ships with the driver (typical for Capacity Block GPU AMIs)."
  type        = bool
  default     = false
}

variable "gpu_operator_enable_gdrcopy" {
  description = <<-EOT
    Whether the GPU Operator should enable gdrcopy (GPUDirect RDMA copy). When true,
    the operator's validator requires the gdrdrv kernel module to be loaded; if the
    module is absent, gdrcopy-validation blocks indefinitely and the NVIDIA device
    plugin never advertises nvidia.com/gpu. Leave false unless the node image ships
    or builds gdrdrv. gdrcopy is a latency optimization, not required for EFA/NCCL.
  EOT
  type        = bool
  default     = false
}

# ── Component versions ────────────────────────────────────────────────────────
# Pinned by default to the versions verified in this project. Override to upgrade.

variable "karpenter_chart_version" {
  description = "Helm chart version for Karpenter (oci://public.ecr.aws/karpenter/karpenter)."
  type        = string
  default     = "1.13.0"
}

variable "gpu_operator_chart_version" {
  description = "Helm chart version for the NVIDIA GPU Operator (helm.ngc.nvidia.com/nvidia)."
  type        = string
  default     = "v25.10.1"
}

variable "efa_device_plugin_chart_version" {
  description = "Helm chart version for aws-efa-k8s-device-plugin (aws.github.io/eks-charts). NOTE: chart version differs from the app/image version."
  type        = string
  default     = "v0.5.29"
}

variable "mpi_operator_version" {
  description = "Kubeflow MPI Operator release tag. The v2beta1 manifest is fetched from GitHub at this tag."
  type        = string
  default     = "v0.6.0"
}

variable "neuron_helm_chart_version" {
  description = "Chart version for neuron-helm-chart (oci://public.ecr.aws/neuron/neuron-helm-chart). Installs the Neuron device plugin (and optional scheduler). Only used when an accelerator pool has device_plugin=\"neuron\"."
  type        = string
  default     = "1.9.0"
}

variable "neuron_enable_scheduler" {
  description = <<-EOT
    Enable the Neuron Scheduler Extension. Required for pods that request more than one
    Neuron device (e.g. tensor-parallel serving across many chips on trn2.48xlarge), so
    that contiguous device IDs are guaranteed. Off by default (single-device workloads
    do not need it). The Node Problem Detector (npd) is always disabled here because
    Karpenter + Neuron DRA/NPD is unsupported.
  EOT
  type        = bool
  default     = false
}

# ── System (control-plane-adjacent) managed node group ────────────────────────

variable "system_node_instance_types" {
  description = "Instance types for the system managed node group that hosts kube-system and the Karpenter controller."
  type        = list(string)
  default     = ["m5.xlarge"]
}

variable "system_node_ami_type" {
  description = "AMI type for the system managed node group (e.g. AL2023_x86_64_STANDARD, AL2023_ARM_64_STANDARD)."
  type        = string
  default     = "AL2023_x86_64_STANDARD"
}

variable "system_node_desired_size" {
  description = "Desired (and min/max) node count for the system managed node group."
  type        = number
  default     = 2
}

# ── CPU node disk and lifecycle ───────────────────────────────────────────────
# (GPU/Neuron node disk, lifetime, and limits are per-pool in var.accelerator_pools.)

variable "cpu_node_volume_size" {
  description = "Root EBS volume size for CPU nodes (e.g. \"50Gi\")."
  type        = string
  default     = "50Gi"
}

variable "cpu_nodepool_cpu_limit" {
  description = "Karpenter CPU NodePool spec.limits.cpu."
  type        = string
  default     = "256"
}

variable "fsx_per_unit_storage_throughput" {
  description = "FSx for Lustre per-unit storage throughput in MB/s/TiB. Valid values for PERSISTENT_2 SSD: 125, 250, 500, 1000."
  type        = number
  default     = 250
}

variable "fsx_storage_capacity_gib" {
  description = "FSx for Lustre storage capacity in GiB. Must be a multiple of 2400 for PERSISTENT_2 SSD."
  type        = number
  default     = 4800
}

variable "fsx_csi_driver_role_arn" {
  description = "ARN of the IRSA / Pod Identity role for the aws-fsx-csi-driver addon. Leave empty to omit the IRSA binding (suitable when using EKS Pod Identity)."
  type        = string
  default     = ""
}

# ── EFS (shared, AZ-independent RWX for Neuron/HF caches) ─────────────────────
# The voice-image-edit app persists compiled NEFFs and the HF cache under
# /mnt/efs/neuron-workspace so that a rescheduled Pod (Karpenter node replacement on
# CB/Spot loss) reuses them instead of recompiling (tens of minutes). EFS is chosen over
# FSx Lustre here because it is multi-AZ / ReadWriteMany: the accelerator pool AZ (e.g.
# trn2 in the Capacity Block AZ) may differ from any single-AZ FSx, and multiple model
# Pods share one cache. See efs.tf.

variable "efs_enabled" {
  description = "Create the shared EFS filesystem, CSI driver, and RWX StorageClass for Neuron/HF caches."
  type        = bool
  default     = true
}

variable "efs_csi_driver_version" {
  description = "Version of the aws-efs-csi-driver EKS addon."
  type        = string
  default     = "v3.3.0-eksbuild.1"
}

variable "cb_alert_email_addresses" {
  description = "List of email addresses to notify 1 hour before the Capacity Block expires. Leave empty to skip SNS subscriptions."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Common tags applied to all resources."
  type        = map(string)
  default = {
    Project   = "distributed-ai"
    ManagedBy = "terraform"
  }
}

# ── CloudFront / demo endpoint ────────────────────────────────────────────────

variable "enable_cloudfront" {
  description = <<-EOT
    Enable the CloudFront → ALB → EKS demo endpoint.

    Two-phase deployment required (see README.md):
      Phase 1 (default false): apply to create ALB via Ingress. Wait for ALB to become active.
      Phase 2 (set true):      apply to create CloudFront distribution and ALB SG rules.

    Setting this to true before the ALB exists will fail because aws_lb data source
    requires the ALB to be present at plan time.
  EOT
  type        = bool
  default     = false
}

variable "alb_controller_chart_version" {
  description = "Helm chart version for aws-load-balancer-controller (aws.github.io/eks-charts)."
  type        = string
  default     = "3.4.1"
}

variable "demo_namespace" {
  description = "Kubernetes namespace for the demo echo application."
  type        = string
  default     = "demo"
}

variable "demo_app_image" {
  description = "Container image for the demo echo server. Pin to a digest or version tag for reproducibility."
  type        = string
  # ealen/echo-server 0.9.2 — pinned digest as of 2025-06-01.
  # Update by running: docker inspect ealen/echo-server:0.9.2 --format '{{index .RepoDigests 0}}'
  default     = "ealen/echo-server:0.9.2"
}

variable "cloudfront_web_acl_id" {
  description = <<-EOT
    Optional ARN of an AWS WAFv2 WebACL (GLOBAL scope, us-east-1) to associate with
    the CloudFront distribution. Leave empty to omit WAF attachment.
    Example: "arn:aws:wafv2:us-east-1:123456789012:global/webacl/my-acl/abc123"
  EOT
  type        = string
  default     = ""
}
