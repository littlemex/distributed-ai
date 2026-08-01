locals {
  # ── EFA capability (dynamic, from AWS API) ───────────────────────────────────
  # EFA topology per pool is resolved at plan time from the EC2 DescribeInstanceTypes API via
  # data.aws_ec2_instance_type (one lookup per pool's representative type). No static table to
  # maintain — new instance generations (g8e, p6, etc.) are automatically correct without any
  # code change. A pool may still override efa_interface_count / efa_multi_card explicitly; when
  # it does not (value < 0 / null), the data source provides the ground truth.

  # Representative instance type per pool (drives EFA derivation). All types in a pool must
  # share EFA topology (see the precondition in karpenter-resources.tf), so the first is safe.
  pool_rep_instance_type = { for k, p in var.accelerator_pools : k => p.instance_types[0] }

  # Resolved EFA topology per pool: explicit pool override wins, else the data source value.
  # efa_supported=false → cards=0. maximum_network_cards is the physical card count that
  # determines the multi-card EFA layout (cards > 1 → one EFA-only interface per card).
  pool_efa = {
    for k, p in var.accelerator_pools : k => {
      count = (
        p.efa_interface_count >= 0
        ? p.efa_interface_count
        : (data.aws_ec2_instance_type.pool_rep[local.pool_rep_instance_type[k]].efa_supported
          ? coalesce(data.aws_ec2_instance_type.pool_rep[local.pool_rep_instance_type[k]].efa_maximum_interfaces, 0)
          : 0)
      )
      multi_card = (
        p.efa_multi_card != null
        ? p.efa_multi_card
        : (data.aws_ec2_instance_type.pool_rep[local.pool_rep_instance_type[k]].efa_supported &&
           coalesce(data.aws_ec2_instance_type.pool_rep[local.pool_rep_instance_type[k]].efa_maximum_interfaces, 0) > 1)
      )
    }
  }

  # Schedulable EFA count a pod may request. With the "1 interface + N efa-only"
  # multi-card layout, card 0 carries the node IP and is NOT advertised as EFA, so
  # a multi-card instance advertises (cards - 1). Single-card instances advertise
  # their full count. Surfaced in outputs.tf so users request the correct number.
  pool_efa_schedulable = {
    for k, e in local.pool_efa : k => (
      e.count <= 0 ? 0 : (e.multi_card ? e.count - 1 : e.count)
    )
  }

  # Karpenter service account name (matches official Helm chart default).
  karpenter_service_account = "karpenter"

  # Namespace where Karpenter is installed.
  karpenter_namespace = "karpenter"

  # IAM role name for Karpenter-provisioned nodes.
  # Deterministic name used in EC2NodeClass.spec.instanceProfile.
  karpenter_node_role_name = "${var.cluster_name}-karpenter-node"

  # Name for the EFA inter-node security group.
  efa_sg_name = "${var.cluster_name}-efa-node"

  # Which accelerator device-plugin stacks are needed, derived from the pools. The GPU
  # add-ons (gpu-addons.tf) and the Neuron add-on (neuron-addons.tf) activate only when a
  # pool of the matching type exists — so a Neuron-only or GPU-only cluster installs just
  # what it uses, and a mixed cluster installs both. EFA is needed if any pool requests it.
  has_gpu_pool    = length([for k, p in var.accelerator_pools : k if p.device_plugin == "nvidia"]) > 0
  has_neuron_pool = length([for k, p in var.accelerator_pools : k if p.device_plugin == "neuron"]) > 0
  has_efa_pool    = length([for k, e in local.pool_efa : k if e.count > 0]) > 0

  # Tags applied to all cluster-owned resources.
  #
  # IMPORTANT: karpenter.sh/discovery is intentionally NOT included here. If it were,
  # this map feeds the VPC module's top-level `tags`, which propagates to EVERY subnet
  # — including the public subnets. Karpenter's subnetSelectorTerms would then match
  # public subnets (IGW route, MapPublicIpOnLaunch=false), stranding nodes with no
  # route to the EC2 API so nodeadm never joins the cluster. The discovery tag must be
  # scoped to private subnets only (see vpc.tf private_subnet_tags) and to the node
  # security group (see eks.tf node_security_group_tags).
  cluster_tags = var.tags

  # Tags applied to Karpenter EC2NodeClass resources (and thus to launched nodes).
  # Derived from var.tags so a single source of truth drives every node tag; the
  # discovery tag is added here (nodes/SG discovery), NOT in cluster_tags (subnets).
  nodeclass_tags = merge(var.tags, {
    "karpenter.sh/discovery" = var.cluster_name
    "Environment"            = var.environment
  })

  # ── Pool normalization layer (ADR 0001) ───────────────────────────────────────
  # Normalizes legacy/new fields into a single effective view per pool. Legacy tfvars produce
  # byte-identical plans (CI-gated). See docs/adr-0001-*.md for field precedence.
  pool_effective = {
    for k, p in var.accelerator_pools : k => {
      capacity_types = (
        p.capacity_types != null ? p.capacity_types :
        p.capacity_type != null ? [p.capacity_type] :
        ["on-demand"]
      )
      has_reserved = (
        p.capacity_types != null
        ? contains(p.capacity_types, "reserved")
        : p.capacity_type == "reserved"
      )
      reservation_ids = distinct(concat(
        try(p.capacity_reservations.ids, []),
        (p.cb_reservation_id != null && p.cb_reservation_id != "") ? [p.cb_reservation_id] : []
      ))
      reservation_tags = try(p.capacity_reservations.tags, {})
      zones = (
        p.zones != null ? p.zones :
        p.zone != "" ? [p.zone] :
        []
      )
    }
  }

  # Disruption preset per pool (ADR D6 precedence: raw field > preset > interruptible > derived).
  # Separated from pool_effective so it can reference n.has_reserved directly (HCL cannot reference
  # sibling keys within the same object literal).
  pool_disruption_preset = {
    for k, p in var.accelerator_pools : k => (
      p.disruption != null ? p.disruption :
      p.interruptible != null ? (p.interruptible ? "reclaim" : "protect") :
      (local.pool_efa[k].count > 0 || local.pool_effective[k].has_reserved) ? "protect" : "reclaim"
    )
  }
}
