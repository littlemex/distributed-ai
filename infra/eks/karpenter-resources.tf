# karpenter-resources.tf
# Accelerated Karpenter NodePools + EC2NodeClasses, rendered uniformly from
# var.accelerator_pools (GPU and Neuron/Trainium), plus an optional CPU-only pool.
#
# Verified facts (VERIFIED_FACTS.md):
#   - Karpenter provider-aws v1.13.0: capacity-type label = karpenter.sh/capacity-type, value = "reserved"
#   - EC2NodeClass v1: spec.capacityReservationSelectorTerms: [{id: cr-xxx}]
#   - expireAfter uses a Go duration string ("24h") or "Never", not ISO 8601
#   - EC2NodeClass v1 interfaceType only accepts "interface" or "efa-only" (NOT "efa")
#   - Karpenter does NOT attach EFA automatically; spec.networkInterfaces must declare it
#   - trn2.48xlarge = 16 network cards / EFA x16; p5en = 16; p5 = 32; g6e = 1 (single card)
#   - Neuron AL2023 AMI ships aws-neuronx-dkms + tools + EFA; device plugin is separate

# Resolve a pinned AMI id from SSM for any pool that specifies ami_ssm_parameter. Used to
# make Neuron/GPU AMI selection deterministic instead of relying on alias family inference.
data "aws_ssm_parameter" "pool_ami" {
  for_each = { for k, p in var.accelerator_pools : k => p if p.ami_ssm_parameter != "" }
  name     = each.value.ami_ssm_parameter
}

locals {
  # ── Per-pool EFA network interfaces ──────────────────────────────────────────
  #
  # Karpenter does NOT attach EFA automatically — spec.networkInterfaces must declare it.
  # The CRD only accepts interfaceType "interface" or "efa-only" (NOT "efa"): a primary
  # "interface" ENA carries the node IP, and each EFA device is a separate "efa-only"
  # interface (RDMA only, no IP).
  #
  #   Single-card (efa_multi_card=false, e.g. g6e): primary on card 0 / device 0, then
  #     efa_interface_count "efa-only" interfaces on card 0 with incrementing deviceIndex.
  #   Multi-card (efa_multi_card=true, e.g. p5/p5en/trn2): primary on card 0 / device 0,
  #     then one "efa-only" interface per network card. The primary already occupies card 0,
  #     so the efa-only interfaces occupy cards 1 .. efa_interface_count-1 (device 0 each),
  #     for efa_interface_count total EFA-capable cards. This never exceeds the card count.
  pool_network_interfaces = {
    for k, p in var.accelerator_pools : k => (
      p.efa_interface_count <= 0 ? [] : concat(
        [{ networkCardIndex = 0, deviceIndex = 0, interfaceType = "interface" }],
        p.efa_multi_card ? [
          for i in range(p.efa_interface_count - 1) : {
            networkCardIndex = i + 1
            deviceIndex      = 0
            interfaceType    = "efa-only"
          }
          ] : [
          for i in range(p.efa_interface_count) : {
            networkCardIndex = 0
            deviceIndex      = i + 1
            interfaceType    = "efa-only"
          }
        ]
      )
    )
  }

  # Per-pool amiSelectorTerms: a pinned SSM-resolved id when ami_ssm_parameter is set,
  # otherwise the family alias (al2023@latest resolves to the Neuron AMI for Neuron
  # instances and the GPU AMI for GPU instances).
  pool_ami_selector_terms = {
    for k, p in var.accelerator_pools : k => (
      p.ami_ssm_parameter != ""
      ? [{ id = data.aws_ssm_parameter.pool_ami[k].value }]
      : [{ alias = p.ami_alias }]
    )
  }

  # ── Shared EC2NodeClass spec ─────────────────────────────────────────────────
  # Fields common to every node class (accelerated pools and CPU). Per-class specs merge
  # their own AMI, blockDeviceMappings, and (for accelerated pools) networkInterfaces /
  # capacityReservationSelectorTerms.
  nodeclass_common = {
    amiFamily = "AL2023"
    subnetSelectorTerms = [{
      tags = { "karpenter.sh/discovery" = var.cluster_name }
    }]
    securityGroupSelectorTerms = [{
      tags = { "karpenter.sh/discovery" = var.cluster_name }
    }]
    instanceProfile = module.karpenter.instance_profile_name
    tags            = local.nodeclass_tags
  }

  # AL2023 nodeadm config shared by accelerated nodes. localStorage Raid0 stripes instance
  # store (NVMe) when present; systemReserved keeps the kubelet stable under heavy memory.
  accelerator_user_data = <<-EOT
    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      kubelet:
        config:
          systemReserved:
            memory: "2Gi"
      instance:
        localStorage:
          strategy: Raid0
  EOT
}

# ── Accelerated EC2NodeClasses (one per accelerator pool) ──────────────────────
resource "kubectl_manifest" "accelerator_nodeclass" {
  for_each = var.accelerator_pools

  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = each.key }
    # capacityReservationSelectorTerms must be OMITTED entirely for on-demand/spot:
    # Karpenter v1 CRD validation rejects an empty [] ("'id' is mutually exclusive"), so
    # we merge the key in only for reserved pools. networkInterfaces is omitted when EFA
    # is disabled (empty list) so Karpenter provisions a single default ENA.
    spec = merge(
      local.nodeclass_common,
      { amiSelectorTerms = local.pool_ami_selector_terms[each.key] },
      each.value.capacity_type == "reserved" ? {
        capacityReservationSelectorTerms = [{ id = each.value.cb_reservation_id }]
      } : {},
      length(local.pool_network_interfaces[each.key]) > 0 ? {
        networkInterfaces = local.pool_network_interfaces[each.key]
      } : {},
      {
        userData = local.accelerator_user_data
        blockDeviceMappings = [{
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = each.value.volume_size
            volumeType          = "gp3"
            deleteOnTermination = true
            encrypted           = true
          }
        }]
      }
    )
  })

  # Guard against the common multi-card EFA misconfiguration: p5/p5en/trn2 expose many EFA
  # interfaces across multiple network cards, so a single-card layout degrades or fails.
  lifecycle {
    precondition {
      condition = !(
        can(regex("^(p5|trn2|trn1|inf2)", each.value.instance_type)) &&
        (each.value.efa_interface_count <= 1 || !each.value.efa_multi_card)
      )
      error_message = "Pool ${each.key} (${each.value.instance_type}) is a multi-card EFA instance: set efa_interface_count (16 for p5en/trn2, 32 for p5) and efa_multi_card = true."
    }
  }

  depends_on = [helm_release.karpenter]
}

# ── Accelerated NodePools (one per accelerator pool) ───────────────────────────
resource "kubectl_manifest" "accelerator_nodepool" {
  for_each = var.accelerator_pools

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = each.key }
    spec = {
      template = {
        metadata = {
          labels = {
            "node-role"             = each.key
            "distributed-ai/device" = each.value.device_plugin # "nvidia" | "neuron"
          }
          # NOTE: Capacity Block nodes carry a `capacity-reservation` taint whose value
          # changes per reservation; pods must tolerate it with operator: Exists. The
          # nvidia/neuron device plugins add their own accelerator taints, which pods
          # tolerate likewise. (Documented as a comment to avoid polluting reserved
          # annotation domains.)
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = each.key
          }
          requirements = [
            {
              # reserved (Capacity Block) | on-demand | spot
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = [each.value.capacity_type]
            },
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = [each.value.instance_type]
            },
            {
              # Zone selection depends on capacity_type:
              #   reserved (Capacity Block): pin to the single CB AZ — CB is allocated in one AZ.
              #   on-demand / spot: allow ALL cluster AZs so Karpenter falls back to another AZ
              #     when one is capacity-exhausted (g6e/p-series InsufficientInstanceCapacity is
              #     common and AZ-specific). This is the resilience EKS is supposed to provide.
              # each.value.zone is still validated to be one of var.azs and documents intent.
              key      = "topology.kubernetes.io/zone"
              operator = "In"
              values   = each.value.capacity_type == "reserved" ? [each.value.zone] : var.azs
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            }
          ]
          # Node lifetime. "Never" by default: Karpenter's ReservedCapacity drains Capacity
          # Block nodes shortly before the reservation ends, so coupling expireAfter to a
          # wall-clock window is unnecessary (and would break plan idempotency).
          expireAfter = each.value.expire_after
        }
      }
      disruption = {
        # Only consolidate truly empty nodes; never consolidate after idle to preserve
        # accelerator nodes (Capacity Block especially).
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "Never"
      }
      limits = {
        cpu    = each.value.cpu_limit
        memory = each.value.memory_limit
      }
    }
  })

  depends_on = [kubectl_manifest.accelerator_nodeclass]
}

# ---------------------------------------------------------------------------
# CPU-only NodePool (on-demand) for controllers and non-GPU workloads.
# Optional; toggled by var.cpu_nodepool_enabled. Reuses nodeclass_common.
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "ec2nodeclass_cpu" {
  count = var.cpu_nodepool_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "cpu" }
    spec = merge(local.nodeclass_common, {
      amiSelectorTerms = [{ alias = "al2023@latest" }]
      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs = {
          volumeSize          = var.cpu_node_volume_size
          volumeType          = "gp3"
          deleteOnTermination = true
          encrypted           = true
        }
      }]
    })
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "nodepool_cpu" {
  count = var.cpu_nodepool_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "cpu" }
    spec = {
      template = {
        metadata = { labels = { "node-role" = "cpu" } }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "cpu"
          }
          requirements = [
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
            },
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = var.cpu_instance_categories
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["4"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            }
          ]
          expireAfter = "Never"
        }
      }
      disruption = {
        # CPU nodes can be reclaimed promptly when idle.
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }
      limits = {
        cpu = var.cpu_nodepool_cpu_limit
      }
    }
  })

  depends_on = [kubectl_manifest.ec2nodeclass_cpu]
}
