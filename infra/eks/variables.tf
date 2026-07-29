variable "region" {
  description = "AWS region where the cluster is deployed."
  type        = string
  default     = "us-east-2"
}

variable "azs" {
  description = <<-EOT
    Availability zones for the VPC and EKS control plane. LEAVE UNSET (null, the default) to
    auto-derive EVERY standard AZ in var.region: the VPC then spans the whole region, so a
    Capacity Block landing in ANY AZ always has a matching subnet. This is the property that
    makes the cluster resilient to a CB's AZ changing between reservations — you never touch
    this file when the CB moves. Set an explicit list only to pin a specific AZ set/order
    (e.g. to exclude an AZ that lacks EKS or your instance type, or to control the subnet
    index order used by var.fsx_subnet_index / var.openzfs_subnet_index). When set it must be
    >= 2 AZs (the EKS control plane requires subnets in at least two AZs). The resolved list
    lives in local.azs (see vpc.tf); subnet CIDRs are auto-derived from it and var.vpc_cidr.
  EOT
  type        = list(string)
  default     = null

  validation {
    # Ternary (not ||) so length() is never called on a null list.
    condition     = var.azs == null ? true : length(var.azs) >= 2
    error_message = "azs must be null (auto-derive all standard region AZs) or an explicit list of at least 2 AZs — the EKS control plane requires subnets in at least two AZs."
  }
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
#   zone                 Single AZ this pool pins to. LEAVE UNSET (""): the resolved zone is
#                        derived automatically (local.pool_zone) —
#                          reserved            → the AZ of the pool's Capacity Block, read from
#                                                the reservation at plan time (local.pool_cb_zone).
#                                                A CB cannot choose its AZ, so deriving it here
#                                                means a CB moving AZ needs only its new
#                                                cb_reservation_id, never a zone edit.
#                          on-demand / spot     → the first resolved AZ (local.azs[0]).
#                        ALL pools pin to a single AZ: EFA/RDMA is not routable across subnets,
#                        so every rank of a multi-node collective must share one AZ. Set an
#                        explicit AZ only to override the default (e.g. spread two on-demand
#                        pools across AZs); it must be one of the resolved local.azs.
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
    # Single AZ to pin to. "" (default) = derive: reserved → CB's AZ, on-demand/spot → azs[0].
    # Set an explicit AZ (one of local.azs) only to override that default.
    zone = optional(string, "")
    # EFA topology is derived from the instance type (locals.efa_capability) unless
    # set explicitly. Leave efa_interface_count = -1 (default) and efa_multi_card = null
    # to auto-derive; set a value to override. 0 disables EFA.
    efa_interface_count = optional(number, -1)
    efa_multi_card      = optional(bool, null)
    # Capacity Block: cb_reservation_id (cr-...) is required for capacity_type "reserved".
    # cb_end_date (RFC3339) optionally schedules a pre-expiry alert for THIS pool.
    cb_reservation_id = optional(string, "")
    cb_end_date       = optional(string, "")
    # EC2 placement group for tight multi-node placement. null = none. "cluster" packs nodes
    # onto one low-latency spine (best for multi-node NCCL on on-demand/spot); "spread" /
    # "partition" reduce correlated failure. DO NOT set on a Capacity Block pool: a CB already
    # colocates its nodes in one UltraCluster, and overlaying a self-made cluster group risks
    # "capacity reserved but placement-group-unsatisfiable" (a validation below enforces this).
    # partition_count applies only to strategy "partition".
    placement_group_strategy = optional(string, null)
    partition_count          = optional(number, null)
    ami_alias                = optional(string, "al2023@latest")
    ami_ssm_parameter        = optional(string, "")
    volume_size              = optional(string, "200Gi")
    # expire_after: Go duration ("24h") or "Never". Node lifetime.
    expire_after = optional(string, "Never")
    # consolidate_after: Go duration ("5m") or "Never". Karpenter scales an empty node
    # down after this idle period. Defaults per capacity_type in locals (on-demand/spot
    # consolidate to control idle cost; reserved keeps nodes for the reservation window).
    consolidate_after = optional(string, "")
    cpu_limit         = optional(string, "10000")
    memory_limit      = optional(string, "100000Gi")
    # CPU architecture of the node host. Defaults to amd64. Set "arm64" for Grace-based
    # accelerator hosts (e.g. GB200 / p6e-gb200); an amd64-only requirement would otherwise
    # leave an arm64 instance type stuck Pending with a requirements mismatch.
    arch = optional(string, "amd64")
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
  # NOTE: "zone must be one of the resolved AZs" is NOT validated here — the resolved AZ list
  # (local.azs) comes from a data source, which a variable validation block cannot reference.
  # It is enforced as a precondition in az.tf (terraform_data.az_invariants) instead.
  validation {
    condition     = alltrue([for k, p in var.accelerator_pools : p.capacity_type != "reserved" || p.cb_reservation_id != ""])
    error_message = "A pool with capacity_type \"reserved\" must set cb_reservation_id (cr-...)."
  }
  validation {
    # Enforce the reservation-id shape at plan time. The CB metadata helper LISTS all
    # reservations and matches ids client-side, so a deleted OR mistyped id degrades quietly to
    # found=false (a WARN) instead of a LOUD AWS error. That is the desired behavior for a
    # rotated-out CB, but it would also swallow a genuine typo — so we catch malformed ids here,
    # before the helper runs. A reservation id is "cr-" + 17 lowercase hex chars.
    condition     = alltrue([for k, p in var.accelerator_pools : p.cb_reservation_id == "" || can(regex("^cr-[0-9a-f]{17}$", p.cb_reservation_id))])
    error_message = "cb_reservation_id must look like a Capacity Reservation id: \"cr-\" followed by 17 lowercase hex characters (e.g. \"cr-0123456789abcdef0\")."
  }
  validation {
    # coalesce(...) avoids passing null to contains() (HCL contains errors on a null value).
    condition     = alltrue([for k, p in var.accelerator_pools : contains(["cluster", "partition", "spread", "none"], coalesce(p.placement_group_strategy, "none"))])
    error_message = "placement_group_strategy must be null or one of \"cluster\", \"partition\", \"spread\"."
  }
  validation {
    # A Capacity Block already places its nodes in one UltraCluster; a self-made placement
    # group can conflict with that fixed placement (capacity reserved but PG-unsatisfiable).
    condition     = alltrue([for k, p in var.accelerator_pools : p.placement_group_strategy == null || p.capacity_type != "reserved"])
    error_message = "Do not set placement_group_strategy on a reserved (Capacity Block) pool — the CB already colocates its nodes in one UltraCluster, and a self-made placement group risks 'capacity reserved but placement-group-unsatisfiable'."
  }
  validation {
    condition     = alltrue([for k, p in var.accelerator_pools : coalesce(p.placement_group_strategy, "none") != "partition" || (coalesce(p.partition_count, 0) >= 1 && coalesce(p.partition_count, 0) <= 7)])
    error_message = "placement_group_strategy \"partition\" requires partition_count in 1..7 (EC2 max 7 partitions per AZ)."
  }
  validation {
    # eventbridge-cb-alarm.tf formats cb_end_date with schedule_expression_timezone = "UTC",
    # which reinterprets any non-Z offset as UTC — e.g. "...+09:00" would fire 9h late.
    # Require a bare UTC ("Z") timestamp so the alert time is unambiguous.
    condition     = alltrue([for k, p in var.accelerator_pools : p.cb_end_date == "" || can(regex("Z$", p.cb_end_date))])
    error_message = "cb_end_date must be UTC (end with \"Z\", e.g. \"2026-01-01T12:00:00Z\") — a non-Z offset is misinterpreted as UTC by the EventBridge schedule and fires at the wrong time."
  }
  validation {
    condition     = alltrue([for k, p in var.accelerator_pools : contains(["amd64", "arm64"], p.arch)])
    error_message = "Each accelerator pool's arch must be \"amd64\" or \"arm64\"."
  }
  validation {
    # A cb_reservation_id set on a non-reserved pool is silently ignored: the NodeClass omits
    # capacityReservationSelectorTerms, so the operator thinks they are drawing on a paid
    # reservation but Karpenter launches on-demand/spot instead (double billing). Flag it.
    condition     = alltrue([for k, p in var.accelerator_pools : p.cb_reservation_id == "" || p.capacity_type == "reserved"])
    error_message = "A pool sets cb_reservation_id but capacity_type is not \"reserved\"; the reservation would be ignored and the pool billed on-demand/spot. Set capacity_type = \"reserved\" or clear cb_reservation_id."
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
    Named AWS CLI/Terraform provider profile. Set this whenever you authenticate via a
    named profile (AWS SSO, an assume-role/Isengard profile, or any ~/.aws/config
    profile) — it is threaded consistently to the aws/helm/kubectl providers and the
    aws-CLI helpers so every path uses the SAME principal. Leave unset (null, the
    default) only when the standard credential chain already resolves to the intended
    principal — static keys in [default], environment variables, an EC2/ECS instance
    role, etc. (e.g. most CI runners). If [default] is a different principal than the
    one you apply with, kubectl/update-kubeconfig on [default] will get "Unauthorized".
  EOT
  type        = string
  default     = null
}

variable "expected_account_id" {
  description = <<-EOT
    Guardrail against applying to the wrong account. When set to a 12-digit account ID,
    a precondition (az.tf) fails the PLAN if the resolved credentials point at a different
    account, before any resource is touched. This is the primary defense against a profile
    mix-up silently re-creating the whole cluster in another account (or duplicate-billing
    filesystems that have no name uniqueness). Leave unset (null, the default) to skip the
    check — but pinning it is strongly recommended for any long-lived cluster. Note the
    value is descriptive, not a credential: it only asserts "these creds had better resolve
    to THIS account".
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.expected_account_id == null || can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "expected_account_id must be a 12-digit AWS account ID (or null to skip the check)."
  }
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
    CIDR blocks for private subnets (one per AZ). LEAVE UNSET (null, the default) to
    auto-derive one large private subnet per resolved AZ from var.vpc_cidr (az.tf carves a /18
    per AZ — 16,384 addresses — from the low half of the VPC via cidrsubnets). Auto-derivation
    always produces exactly one CIDR per AZ, so it can never desync from the AZ list the way a
    hand-maintained list can. Node workloads run here, hence the large /18: this follows AWS's
    awslabs/awsome-distributed-ai HyperPod-EKS "public small, private huge" principle, because
    every GPU/Neuron node holds dozens of Pod ENIs plus EFA-only ENIs. Set an explicit list
    only to override the layout — then it MUST have exactly length(local.azs) entries (a
    precondition in az.tf enforces this) and must not overlap the public subnets. Do NOT use
    /24 — a single trn2/p5 node's ENIs can exhaust it.
  EOT
  type        = list(string)
  default     = null
}

variable "public_subnet_cidrs" {
  description = <<-EOT
    CIDR blocks for public subnets (one per AZ). LEAVE UNSET (null, the default) to auto-derive
    one small public subnet per resolved AZ from var.vpc_cidr (az.tf carves a /24 per AZ from
    the TOP of the VPC, so it never eats into the large private ranges). NAT gateways and load
    balancers only, hence the small /24 (251 usable), matching the awslabs/awsome-distributed-ai
    reference. Set an explicit list only to override — then it MUST have exactly
    length(local.azs) entries (a precondition in az.tf enforces this).
  EOT
  type        = list(string)
  default     = null
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

variable "training_operator_enabled" {
  description = "Install the Kubeflow Training Operator (PyTorchJob multi-node launcher). Disable for inference-only clusters that do not run PyTorchJobs."
  type        = bool
  default     = true
}

variable "training_operator_version" {
  description = "Kubeflow Training Operator release tag. Used only for the vendored manifest filename (manifests/training-operator-<version>.yaml); the manifest is committed to the repo, not fetched at plan time."
  type        = string
  default     = "v1.9.0"
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

variable "system_node_volume_size" {
  # The default AL2023 MNG root volume (~20 GiB) leaves little headroom once
  # kube-system images + logs land, and any pod that slips onto this tier can push
  # it into ephemeral-storage eviction. 50 GiB gives the sanctuary comfortable slack
  # without hosting workload images (those belong on the cpu pool). Changing this
  # rolls (replaces) the system nodes — apply in a calm window (migration step 6 in
  # docs/node-role-separation.md).
  description = "Root EBS volume size (GiB) for the system managed node group."
  type        = number
  default     = 50
}

# ── CPU node disk and lifecycle ───────────────────────────────────────────────
# (GPU/Neuron node disk, lifetime, and limits are per-pool in var.accelerator_pools.)

variable "cpu_node_volume_size" {
  # The cpu pool is where operators (gpu/mpi/kuberay) and large-image workloads
  # (a KubeRay head pulling the ~14-18GB slime/miles images) land. Such an image
  # needs ~40GB during pull (compressed + extracted layers) plus head logs / GCS /
  # object spilling; the old 50Gi default evicted the head mid-pull. 150Gi (gp3,
  # ~$12/node/mo — noise vs a p5en cluster) is a SAFE default: "unsafe default +
  # documented warning" demonstrably failed to prevent that incident. Lower it only
  # on cost-sensitive clusters that never schedule a large-image pod on the cpu pool.
  description = "Root EBS volume size for CPU nodes (e.g. \"150Gi\"; safe for a KubeRay head / large RL images. Lower only if no large-image pod targets the cpu pool)."
  type        = string
  default     = "150Gi"
}

variable "cpu_nodepool_cpu_limit" {
  description = "Karpenter CPU NodePool spec.limits.cpu."
  type        = string
  default     = "256"
}

variable "fsx_enabled" {
  description = <<-EOT
    Create the FSx for Lustre FILE SYSTEM and a static PersistentVolume bound to it (no
    dynamic-provisioning StorageClass — see fsx.tf). This gates only the filesystem/SG/PV;
    the aws-fsx-csi-driver add-on is installed unconditionally as permanent infrastructure
    (a CSI driver is a cluster capability, decoupled from whether any filesystem currently
    exists). ON by default: with FSx Lustre off there is no high-throughput scratch for the
    training samples to write to. FSx Lustre is single-AZ (see var.fsx_subnet_index) — the
    whole cluster pins accelerators to one AZ (EFA/RDMA is intra-AZ, Capacity Block is
    single-AZ), so a multi-AZ filesystem would be the anomaly. This is the high-throughput
    scratch/checkpoint layer; FSx OpenZFS (var.openzfs_enabled) is the NFS home/shared layer,
    mirroring the awsome-distributed-ai two-layer (Lustre + OpenZFS) storage design. EFS
    (var.efs_enabled) is a demoted opt-in multi-AZ RWX cache.
  EOT
  type        = bool
  default     = true
}

variable "fsx_csi_driver_version" {
  description = "Version of the aws-fsx-csi-driver EKS add-on (FSx for Lustre). Installed unconditionally (see fsx.tf)."
  type        = string
  default     = "v1.9.0-eksbuild.1"
}

variable "fsx_per_unit_storage_throughput" {
  description = "FSx for Lustre per-unit storage throughput in MB/s/TiB. Valid values for PERSISTENT_2 SSD: 125, 250, 500, 1000."
  type        = number
  default     = 250
  validation {
    # Otherwise the invalid value only surfaces as a CreateFileSystem API error minutes into apply.
    condition     = contains([125, 250, 500, 1000], var.fsx_per_unit_storage_throughput)
    error_message = "fsx_per_unit_storage_throughput must be one of 125, 250, 500, 1000 (PERSISTENT_2 SSD)."
  }
}

variable "fsx_storage_capacity_gib" {
  description = "FSx for Lustre storage capacity in GiB. Must be a multiple of 2400 for PERSISTENT_2 SSD."
  type        = number
  default     = 4800
  validation {
    # PERSISTENT_2 SSD allows 1200 GiB, then 2400 GiB and any multiple of 2400. Do not reject
    # the valid 1200 GiB tier.
    condition     = var.fsx_storage_capacity_gib == 1200 || (var.fsx_storage_capacity_gib >= 2400 && var.fsx_storage_capacity_gib % 2400 == 0)
    error_message = "fsx_storage_capacity_gib must be 1200, 2400, or a multiple of 2400 (PERSISTENT_2 SSD tier sizes)."
  }
}

variable "fsx_subnet_index" {
  description = <<-EOT
    Index into module.vpc.private_subnets (i.e. into local.azs) for the single-AZ FSx
    filesystem. FSx Lustre is single-AZ; mounting from a pod in a DIFFERENT AZ works within
    the VPC but adds cross-AZ data-transfer cost and latency, so set this to match the AZ
    of whichever accelerator pool will use it for best performance (0 = local.azs[0]).
  EOT
  type        = number
  default     = 0
  # The upper bound (index < number of resolved AZs) is enforced in az.tf's precondition,
  # because the resolved AZ count (local.azs) comes from a data source that a variable
  # validation block cannot reference. Here we only reject a negative index.
  validation {
    condition     = var.fsx_subnet_index >= 0
    error_message = "fsx_subnet_index must be >= 0 (it indexes into the per-AZ private subnets)."
  }
}

# ── FSx for OpenZFS (single-AZ NFS home/shared layer) ────────────────────────
# The second half of the awsome-distributed-ai two-layer storage design: FSx Lustre is the
# high-throughput scratch, FSx OpenZFS is the NFS-based home/general shared filesystem that
# handles many small files without the IOPS saturation Lustre hits on that pattern. Single-AZ
# to match the rest of the cluster (all accelerator pools pin to one AZ). The CSI driver is
# NOT an EKS managed add-on (only aws-fsx-csi-driver, for Lustre, is) so it is installed via
# Helm; see openzfs.tf.

variable "openzfs_enabled" {
  description = <<-EOT
    Create the FSx for OpenZFS FILE SYSTEM and a static PersistentVolume bound to it. Gates
    only the filesystem/SG/PV; the aws-fsx-openzfs-csi-driver Helm release is installed
    unconditionally as permanent infrastructure (same decoupling as the Lustre/EFS drivers).
    ON by default: this is the NFS home/shared layer (/shared) the training samples mount, so
    turning it off leaves nothing for them to write to. SINGLE_AZ_1 (non-HA) placement pins to
    var.openzfs_subnet_index — keep it aligned with the accelerator pool that uses it, for the
    same intra-AZ reason as FSx Lustre.
  EOT
  type        = bool
  default     = true
}

variable "openzfs_csi_driver_chart_version" {
  description = "Version of the aws-fsx-openzfs-csi-driver Helm chart (kubernetes-sigs). Not an EKS managed add-on. 1.2.0 is the latest published chart in the kubernetes-sigs index (1.3.0 does not exist)."
  type        = string
  default     = "1.2.0"
}

variable "openzfs_storage_capacity_gib" {
  description = "FSx OpenZFS storage capacity in GiB. Minimum 64."
  type        = number
  default     = 256
  validation {
    # The API rejects < 64 GiB only minutes into CreateFileSystem; catch it at plan time.
    condition     = var.openzfs_storage_capacity_gib >= 64
    error_message = "openzfs_storage_capacity_gib must be at least 64 (FSx OpenZFS minimum)."
  }
}

variable "openzfs_throughput_capacity" {
  description = "FSx OpenZFS throughput capacity in MB/s. Valid for SINGLE_AZ_1 (non-HA): 64, 128, 256, 512, 1024, 2048, 3072, 4096."
  type        = number
  default     = 256
  validation {
    # SINGLE_AZ_2/Multi-AZ use a different ladder (160, 320, ...); this module deploys
    # SINGLE_AZ_1 (non-HA), whose valid values are the 64-based ladder. An invalid value
    # otherwise only surfaces as a CreateFileSystem API error minutes into apply.
    condition     = contains([64, 128, 256, 512, 1024, 2048, 3072, 4096], var.openzfs_throughput_capacity)
    error_message = "openzfs_throughput_capacity must be one of 64, 128, 256, 512, 1024, 2048, 3072, 4096 (SINGLE_AZ_1 non-HA)."
  }
}

variable "openzfs_subnet_index" {
  description = <<-EOT
    Index into module.vpc.private_subnets (i.e. into local.azs) for the single-AZ FSx OpenZFS
    filesystem. Access is over NFS within the VPC; mounting from a pod in a DIFFERENT AZ works
    but adds cross-AZ data-transfer cost, so set this to match the AZ of the accelerator
    pool that uses it (0 = local.azs[0]).
  EOT
  type        = number
  default     = 0
  # Upper bound (index < resolved AZ count) enforced in az.tf's precondition; see fsx_subnet_index.
  validation {
    condition     = var.openzfs_subnet_index >= 0
    error_message = "openzfs_subnet_index must be >= 0 (it indexes into the per-AZ private subnets)."
  }
}

# ── EFS (demoted opt-in, AZ-independent RWX for Neuron/HF caches) ─────────────
# EFS is DEMOTED from the default storage set. The primary layers are now the two single-AZ
# FSx filesystems (Lustre scratch + OpenZFS NFS home), matching awsome-distributed-ai. A
# regional multi-AZ filesystem is the anomaly in a cluster that deliberately pins every
# accelerator pool to one AZ, so EFS is opt-in for the specific case where it earns its keep:
# the voice-image-edit app persists compiled NEFFs and the HF cache under
# /mnt/efs/neuron-workspace, and a Pod rescheduled onto a DIFFERENT AZ (Karpenter node
# replacement on CB/Spot loss) must still re-mount that cache to skip the multi-ten-minute
# recompile — the one workload where multi-AZ RWX genuinely helps. See efs.tf.
#
# The aws-efs-csi-driver add-on is installed UNCONDITIONALLY (permanent infra, decoupled from
# this flag); var.efs_enabled gates only the filesystem/mount-targets/PV.

variable "efs_enabled" {
  description = <<-EOT
    Create the shared EFS FILE SYSTEM, mount targets, and RWX StorageClass/PV for Neuron/HF
    caches. Gates only the filesystem/mount-targets/PV; the aws-efs-csi-driver add-on is
    installed unconditionally as permanent infrastructure (see efs.tf). OFF by default: EFS is
    demoted in favour of the two single-AZ FSx layers (Lustre + OpenZFS). Enable only for the
    multi-AZ RWX cache case described above.
  EOT
  type        = bool
  default     = false
}

variable "efs_csi_driver_version" {
  description = "Version of the aws-efs-csi-driver EKS add-on. Installed unconditionally (see efs.tf)."
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
