locals {
  # ── EFA capability lookup ────────────────────────────────────────────────────
  # Maps an EC2 instance type to its EFA topology so pools never hand-enter these
  # numbers (a common source of error — e.g. requesting 16 EFA on p5en, which
  # advertises only 15 schedulable; see efa_schedulable below). A pool may still
  # override efa_interface_count / efa_multi_card explicitly; when it does not
  # (value < 0), the capability is derived from this table.
  #
  #   cards          = number of EFA-capable network cards on the instance
  #   multi_card     = true when EFA spans multiple cards (p5/p5en/trn2), false for
  #                    single-card instances (g6e) that place all EFA on card 0
  # Extend this table as new accelerator instance types are adopted.
  efa_capability = {
    "p5.48xlarge"    = { cards = 32, multi_card = true }
    "p5e.48xlarge"   = { cards = 32, multi_card = true }
    "p5en.48xlarge"  = { cards = 16, multi_card = true }
    "trn2.48xlarge"  = { cards = 16, multi_card = true }
    "trn1.32xlarge"  = { cards = 8, multi_card = true }
    "trn1n.32xlarge" = { cards = 16, multi_card = true }
    "g6e.12xlarge"   = { cards = 1, multi_card = false }
    "g6e.24xlarge"   = { cards = 1, multi_card = false }
    "g6e.48xlarge"   = { cards = 1, multi_card = false }
  }

  # Representative instance type per pool (drives EFA derivation). All types in a pool must
  # share EFA topology (see the precondition in karpenter-resources.tf), so the first is safe.
  pool_rep_instance_type = { for k, p in var.accelerator_pools : k => p.instance_types[0] }

  # Resolved EFA topology per pool: use the explicit pool value when provided
  # (efa_interface_count >= 0), else fall back to the lookup table, else 0 (no EFA).
  pool_efa = {
    for k, p in var.accelerator_pools : k => {
      count = (
        p.efa_interface_count >= 0
        ? p.efa_interface_count
        : try(local.efa_capability[local.pool_rep_instance_type[k]].cards, 0)
      )
      multi_card = (
        p.efa_multi_card != null
        ? p.efa_multi_card
        : try(local.efa_capability[local.pool_rep_instance_type[k]].multi_card, false)
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
}
