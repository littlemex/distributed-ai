locals {
  # Karpenter service account name (matches official Helm chart default).
  karpenter_service_account = "karpenter"

  # Namespace where Karpenter is installed.
  karpenter_namespace = "karpenter"

  # IAM role name for Karpenter-provisioned nodes.
  # Deterministic name used in EC2NodeClass.spec.instanceProfile.
  karpenter_node_role_name = "${var.cluster_name}-karpenter-node"

  # Name for the EFA inter-node security group.
  efa_sg_name = "${var.cluster_name}-efa-node"

  # Whether a Capacity Block reservation ID has been supplied (drives the CB expiry alert).
  has_cb = var.cb_reservation_id != ""

  # Which accelerator device-plugin stacks are needed, derived from the pools. The GPU
  # add-ons (gpu-addons.tf) and the Neuron add-on (neuron-addons.tf) activate only when a
  # pool of the matching type exists — so a Neuron-only or GPU-only cluster installs just
  # what it uses, and a mixed cluster installs both. EFA is needed if any pool requests it.
  has_gpu_pool    = length([for k, p in var.accelerator_pools : k if p.device_plugin == "nvidia"]) > 0
  has_neuron_pool = length([for k, p in var.accelerator_pools : k if p.device_plugin == "neuron"]) > 0
  has_efa_pool    = length([for k, p in var.accelerator_pools : k if p.efa_interface_count > 0]) > 0

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
