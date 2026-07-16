variable "region" {
  description = "AWS region where the cluster is deployed."
  type        = string
  default     = "us-east-2"
}

variable "azs" {
  description = <<-EOT
    Availability zones for the VPC and EKS control plane. EKS requires subnets in at least
    two AZs. Each accelerator pool pins to a single AZ (its `zone`, one of these) so that
    EFA/RDMA collectives stay intra-AZ and Capacity Block placement (single-AZ) is honored,
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
#   instance_types       List of EC2 types Karpenter may launch (e.g. ["g6e.12xlarge"] or
#                        ["g6e.12xlarge","g6e.24xlarge"]). All must share the same EFA topology
#                        (validated). The first entry drives EFA derivation.
#   device_plugin        "nvidia" | "neuron" — selects which device-plugin add-on advertises
#                        the accelerator and which resource name pods request
#                        (nvidia.com/gpu vs aws.amazon.com/neuron).
#   capacity_type        "reserved" (Capacity Block) | "on-demand" | "spot".
#   zone                 Single AZ for the pool (must be one of var.azs). ALL pools pin to
#                        this AZ: EFA/RDMA traffic is not routable across subnets, so every
#                        rank of a multi-node collective must share one AZ; Capacity Block is
#                        single-AZ anyway. (There is no cross-AZ fallback — that would break
#                        multi-node EFA. Use var.azs[0] if you have no preference.)
#   efa_interface_count  EFA interfaces for the instance. Default -1 = derive from the
#                        instance type (locals.efa_capability). Set explicitly to override;
#                        0 disables EFA. NOTE: with the multi-card layout the SCHEDULABLE EFA
#                        a pod may request is (count - 1) — card 0 carries the node IP. The
#                        module surfaces the schedulable number in `terraform output`.
#   efa_multi_card       null (default) = derive from the instance type. true = one EFA per
#                        network card (p5/p5en/trn2); false = all EFA on card 0 (g6e).
#   ami_alias            Karpenter amiSelectorTerms alias, e.g. "al2023@latest". Used when
#                        ami_ssm_parameter is empty. For Neuron instances the AL2023 alias
#                        resolves to the Neuron AMI variant.
#   ami_ssm_parameter    Optional SSM parameter path for a pinned AMI id. When non-empty it
#                        overrides ami_alias (use for deterministic Neuron/GPU AMI selection).
#   cb_reservation_id    Capacity Block reservation id (cr-...) for capacity_type "reserved".
#                        Empty otherwise; the selector term is omitted for on-demand/spot.
#   cb_end_date          Optional RFC3339 CB expiry; schedules a per-pool pre-expiry SNS alert.
#   volume_size          Root EBS volume size (e.g. "200Gi").
#   expire_after         Karpenter NodePool expireAfter ("Never" or a Go duration).
#   consolidate_after    Karpenter empty-node consolidation delay ("5m", "Never", or "" to use
#                        the per-capacity_type default: on-demand/spot consolidate to limit idle
#                        cost, reserved keeps nodes for the reservation window).
#   cpu_limit / memory_limit  Karpenter NodePool spec.limits caps.
variable "accelerator_pools" {
  description = "Map of accelerated Karpenter NodePools (GPU and/or Neuron). See the field reference above."
  type = map(object({
    # One or more EC2 types Karpenter may launch for this pool. All types in a pool must
    # share the same EFA topology (validated) so the network-interface layout is correct;
    # list several compatible sizes (e.g. ["g6e.12xlarge","g6e.24xlarge"]) to give Karpenter
    # capacity flexibility. The first entry is the representative used for EFA derivation.
    instance_types = list(string)
    device_plugin  = string # "nvidia" | "neuron"
    capacity_type  = string # "reserved" | "on-demand" | "spot"
    zone           = string
    # EFA topology is derived from the instance type (locals.efa_capability) unless
    # set explicitly. Leave efa_interface_count = -1 (default) and efa_multi_card = null
    # to auto-derive; set a value to override. 0 disables EFA.
    efa_interface_count = optional(number, -1)
    efa_multi_card      = optional(bool, null)
    # Capacity Block: cb_reservation_id (cr-...) is required for capacity_type "reserved".
    # cb_end_date (RFC3339) optionally schedules a pre-expiry alert for THIS pool.
    cb_reservation_id = optional(string, "")
    cb_end_date       = optional(string, "")
    ami_alias         = optional(string, "al2023@latest")
    ami_ssm_parameter = optional(string, "")
    volume_size       = optional(string, "200Gi")
    # expire_after: Go duration ("24h") or "Never". Node lifetime.
    expire_after = optional(string, "Never")
    # consolidate_after: Go duration ("5m") or "Never". Karpenter scales an empty node
    # down after this idle period. Defaults per capacity_type in locals (on-demand/spot
    # consolidate to control idle cost; reserved keeps nodes for the reservation window).
    consolidate_after = optional(string, "")
    cpu_limit         = optional(string, "10000")
    memory_limit      = optional(string, "100000Gi")
  }))
  # Default is empty: the module deploys a control plane + system nodes with no accelerator
  # pools, so it is Region-agnostic (no hardcoded AZ). The quick start supplies one pool via
  # terraform.tfvars. See terraform.tfvars.example for ready-to-use pool definitions.
  default = {}
  validation {
    condition     = alltrue([for k, p in var.accelerator_pools : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", k))])
    error_message = "Each accelerator pool key becomes a Kubernetes resource name and must be RFC1123: lowercase alphanumeric and '-', starting/ending alphanumeric."
  }
  validation {
    condition     = alltrue([for k, p in var.accelerator_pools : length(p.instance_types) > 0])
    error_message = "Each accelerator pool must list at least one instance type in instance_types."
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
  validation {
    # eventbridge-cb-alarm.tf formats cb_end_date with schedule_expression_timezone = "UTC",
    # which reinterprets any non-Z offset as UTC — e.g. "...+09:00" would fire 9h late.
    # Require a bare UTC ("Z") timestamp so the alert time is unambiguous.
    condition     = alltrue([for k, p in var.accelerator_pools : p.cb_end_date == "" || can(regex("Z$", p.cb_end_date))])
    error_message = "cb_end_date must be UTC (end with \"Z\", e.g. \"2026-01-01T12:00:00Z\") — a non-Z offset is misinterpreted as UTC by the EventBridge schedule and fires at the wrong time."
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

# Capacity Block reservation id and expiry are now per-pool fields on accelerator_pools
# (cb_reservation_id / cb_end_date). The old top-level cb_reservation_id / cb_end_date
# variables were removed; a cluster can hold several Capacity Blocks, one per reserved pool.

variable "aws_profile" {
  description = <<-EOT
    Named AWS CLI/Terraform provider profile. Leave unset (null, the default) to use
    the standard credential chain instead — environment variables, an EC2/ECS
    instance role, or AWS SSO — which is required for users with no ~/.aws/config
    profile named "default" (e.g. most CI runners).
  EOT
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = <<-EOT
    CIDR block for the VPC. /16 (65,536 addresses) because accelerated ML nodes consume IPs
    heavily: the VPC CNI assigns many secondary IPs per node, and multi-card EFA instances
    (trn2.48xlarge = 16 EFA-only ENIs, p5en = 16, p5 = 32) each consume an IP per ENI. A /21
    or /24 exhausts almost immediately and leaves the EKS control plane unable to place its
    management ENIs (cluster goes IMPAIRED / InsufficientFreeAddresses). AWS's own
    awslabs/awsome-distributed-ai HyperPod-EKS reference sizes private subnets at /16 each.
  EOT
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = <<-EOT
    CIDR blocks for private subnets (one per AZ). Node workloads run here, so these are made
    large: the default /18 = 16,384 addresses per subnet. Two /18s plus the small /24 public
    subnets fit inside the /16 VPC without overlap and leave 10.0.128.0/17 free for growth.
    This follows AWS's awslabs/awsome-distributed-ai HyperPod-EKS reference principle of
    "public small, private huge" (its VPC is 10.192.0.0/16 with tiny /24 public subnets),
    because every GPU/Neuron node holds dozens of Pod ENIs plus EFA-only ENIs. Do NOT use /24
    — a single trn2/p5 node's ENIs can exhaust it. Do NOT use two /17s either: they consume
    the entire /16 and collide with the public /24s (InvalidSubnet.Conflict at apply).
  EOT
  type        = list(string)
  default     = ["10.0.0.0/18", "10.0.64.0/18"]
}

variable "public_subnet_cidrs" {
  description = <<-EOT
    CIDR blocks for public subnets (one per AZ). NAT gateways and load balancers only, so
    these are kept small (/24 = 251 usable), matching the awslabs/awsome-distributed-ai reference
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

variable "mpi_operator_enabled" {
  description = "Install the Kubeflow MPI Operator (multi-node MPIJob launcher). Disable for inference-only clusters that do not run MPIJobs."
  type        = bool
  default     = true
}

variable "mpi_operator_version" {
  description = "Kubeflow MPI Operator release tag. Used only for the vendored manifest filename (manifests/mpi-operator-<version>.yaml); the manifest is committed to the repo, not fetched at plan time."
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

variable "fsx_enabled" {
  description = <<-EOT
    Create the FSx for Lustre file system, CSI driver, and a static PersistentVolume bound
    to it (no dynamic-provisioning StorageClass — see fsx.tf). Off by default: FSx
    PERSISTENT_2 provisions terabytes of SSD that bill continuously while the cluster
    exists, which the quick start should not incur. Enable for training runs that need a
    high-throughput single-AZ scratch/checkpoint filesystem. (EFS, gated separately by
    var.efs_enabled, is the multi-AZ RWX cache option.)
  EOT
  type        = bool
  default     = false
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

variable "fsx_subnet_index" {
  description = <<-EOT
    Index into module.vpc.private_subnets (i.e. into var.azs) for the single-AZ FSx
    filesystem. FSx Lustre mounts are only routable from the same AZ, so this should match
    the `zone` of whichever accelerator pool will use it (0 = var.azs[0], 1 = var.azs[1]).
  EOT
  type        = number
  default     = 0
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

variable "enable_demo_app" {
  description = <<-EOT
    Create the AWS Load Balancer Controller and the demo echo app (Namespace,
    Deployment, Service, Ingress → an internet-facing ALB). Off by default: a
    fresh apply with no accelerator pools should not stand up a public,
    unauthenticated endpoint. The demo Deployment's Pod is pinned to the CPU
    NodePool (node-role=cpu) via nodeSelector, so also set
    var.cpu_nodepool_enabled = true or it stays Pending forever.
  EOT
  type        = bool
  default     = false
}

variable "enable_cloudfront" {
  description = <<-EOT
    Enable the CloudFront → ALB → EKS demo endpoint. Requires enable_demo_app = true.

    Two-phase deployment required (see README.md):
      Phase 1 (default false): apply to create ALB via Ingress. Wait for ALB to become active.
      Phase 2 (set true):      apply to create CloudFront distribution and ALB SG rules.

    Setting this to true before the ALB exists will fail because aws_lb data source
    requires the ALB to be present at plan time.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_cloudfront || var.enable_demo_app
    error_message = "enable_cloudfront requires enable_demo_app = true (CloudFront fronts the demo app's ALB)."
  }
}

variable "alb_controller_chart_version" {
  description = "Helm chart version for aws-load-balancer-controller (aws.github.io/eks-charts)."
  type        = string
  default     = "3.4.1"
}

variable "alb_controller_app_version" {
  description = <<-EOT
    aws-load-balancer-controller release tag used ONLY to fetch its upstream IAM
    policy JSON (docs/install/iam_policy.json) from GitHub. This chart version's
    app version happens to share the same "3.x" number as the chart today, but
    chart and app versions are independent series (e.g. chart 1.1.6 shipped app
    v2.1.3) — override this separately if you pin an older/newer chart version.
  EOT
  type        = string
  default     = "3.4.1"
}

variable "demo_namespace" {
  description = "Kubernetes namespace for the demo echo application."
  type        = string
  default     = "demo"
}

variable "demo_app_image" {
  description = "Container image for the demo echo server. For production, pin to an immutable digest (image@sha256:...) rather than a mutable tag."
  type        = string
  # Version tag (mutable). Replace with a digest for reproducibility, e.g.:
  #   ealen/echo-server@sha256:<digest>  (docker inspect ealen/echo-server:0.9.2 --format '{{index .RepoDigests 0}}')
  default = "ealen/echo-server:0.9.2"
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
