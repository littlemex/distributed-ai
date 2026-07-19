# karpenter-resources.tf
# Accelerated Karpenter NodePools + EC2NodeClasses, rendered uniformly from
# var.accelerator_pools (GPU and Neuron/Trainium), plus an optional CPU-only pool.
#
# Verified facts:
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
  # EFA topology comes from local.pool_efa (derived from the instance type unless the pool
  # overrides it — see locals.tf), so these numbers are never hand-entered per pool.
  pool_network_interfaces = {
    for k, p in var.accelerator_pools : k => (
      local.pool_efa[k].count <= 0 ? [] : concat(
        [{ networkCardIndex = 0, deviceIndex = 0, interfaceType = "interface" }],
        local.pool_efa[k].multi_card ? [
          for i in range(local.pool_efa[k].count - 1) : {
            networkCardIndex = i + 1
            deviceIndex      = 0
            interfaceType    = "efa-only"
          }
          ] : [
          for i in range(local.pool_efa[k].count) : {
            networkCardIndex = 0
            deviceIndex      = i + 1
            interfaceType    = "efa-only"
          }
        ]
      )
    )
  }

  # Per-pool consolidation default (overridable via pool.consolidate_after). Reserved
  # (Capacity Block) nodes are kept for the reservation window; on-demand/spot empty nodes
  # consolidate after a short idle to limit cost. "Never" disables idle consolidation.
  pool_consolidate_after = {
    for k, p in var.accelerator_pools : k => (
      p.consolidate_after != "" ? p.consolidate_after :
      (p.capacity_type == "reserved" ? "Never" : "5m")
    )
  }

  # Per-pool amiSelectorTerms: a pinned SSM-resolved id when ami_ssm_parameter is set,
  # otherwise the family alias (al2023@latest resolves to the Neuron AMI for Neuron
  # instances and the GPU AMI for GPU instances).
  pool_ami_selector_terms = {
    for k, p in var.accelerator_pools : k => (
      p.ami_ssm_parameter != ""
      # nonsensitive(): an AMI id is not a secret, and marking it sensitive would redact the
      # entire EC2NodeClass body from `terraform plan` (it flows through yamlencode).
      ? [{ id = nonsensitive(data.aws_ssm_parameter.pool_ami[k].value) }]
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

# ── EC2 placement groups for pools that request one ────────────────────────────
# Karpenter selects an existing placement group via placementGroupSelector but does not
# create one, so we create it here and reference it by name in the EC2NodeClass. Only
# non-reserved pools reach here (a validation forbids placement_group_strategy on CB pools).
# Note: a placement group cannot be deleted while instances are still in it, so a pool
# teardown must drain nodes first (the existing wait_for_node_drain ordering covers this).
resource "aws_placement_group" "accelerator" {
  for_each = { for k, p in var.accelerator_pools : k => p if p.placement_group_strategy != null }

  name            = "${var.cluster_name}-${each.key}"
  strategy        = each.value.placement_group_strategy
  partition_count = each.value.placement_group_strategy == "partition" ? each.value.partition_count : null

  tags = merge(var.tags, { Name = "${var.cluster_name}-${each.key}" })
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
      each.value.placement_group_strategy != null ? {
        placementGroupSelector = { name = aws_placement_group.accelerator[each.key].name }
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

  lifecycle {
    # Guard 1: every instance type in the pool must share one EFA topology, because a single
    # networkInterfaces layout is rendered for the whole pool. Types absent from the lookup
    # table default to {cards=0, multi_card=false}; mixing (e.g. g6e + p5en) is rejected here.
    precondition {
      condition = length(distinct([
        for t in each.value.instance_types :
        format("%d/%t", try(local.efa_capability[t].cards, 0), try(local.efa_capability[t].multi_card, false))
      ])) == 1
      error_message = "Pool ${each.key} mixes instance types with different EFA topologies (${join(", ", each.value.instance_types)}). All instance_types in a pool must share the same EFA card count and multi-card layout."
    }
    # Guard 2: a known multi-card EFA instance must not resolve to a single-card layout.
    # Checks the RESOLVED topology (local.pool_efa) using the representative type, so it fires
    # only on a genuine override mistake — not on single-NIC/non-EFA types (trn1.2xlarge, inf2).
    # count == 0 is exempt: that is an explicit "disable EFA on this pool" override, not a
    # misconfiguration.
    precondition {
      condition = (
        local.pool_efa[each.key].count == 0 ||
        !(
          try(local.efa_capability[local.pool_rep_instance_type[each.key]].multi_card, false) &&
          (local.pool_efa[each.key].count <= 1 || !local.pool_efa[each.key].multi_card)
        )
      )
      error_message = "Pool ${each.key} (${local.pool_rep_instance_type[each.key]}) is a multi-card EFA instance but resolved to a single-card layout. Leave efa_interface_count/efa_multi_card unset to auto-derive, set efa_multi_card = true with the correct count, or set efa_interface_count = 0 to disable EFA."
    }
    # Guard 3: never silently fall back to EFA=0 for an unknown instance type. If the
    # representative type is absent from local.efa_capability AND the pool did not set
    # efa_interface_count explicitly, the derivation would quietly yield 0 — producing a
    # single-ENA node (no EFA) that "works but runs multi-node NCCL over TCP at a fraction of
    # the bandwidth", or a pod that Pends forever if it requests vpc.amazonaws.com/efa. Force
    # an explicit decision: add the type to the table, or set efa_interface_count (0 to opt
    # out of EFA on purpose, or the real card count).
    precondition {
      condition = (
        contains(keys(local.efa_capability), local.pool_rep_instance_type[each.key]) ||
        each.value.efa_interface_count >= 0
      )
      error_message = "Pool ${each.key} uses instance type ${local.pool_rep_instance_type[each.key]}, which is not in the EFA capability table (locals.tf), and does not set efa_interface_count. Add the type to the table, or set efa_interface_count explicitly (0 to disable EFA, or the instance's EFA card count) so EFA is never silently disabled."
    }
    # Guard 4: a manual efa_interface_count override must not exceed the instance's physical
    # card count when the type is known. Over-counting (e.g. 32 on p5en's 16 cards) makes
    # Karpenter render networkInterfaces with cards that do not exist; RunInstances fails and
    # Karpenter retries in a loop with the failure only in its event log.
    precondition {
      # try() is required: Terraform evaluates local.efa_capability[type] even when the
      # contains() guard is false (no short-circuit for index errors), so an unknown type
      # would raise "Invalid index" instead of passing. try(..., big) makes an unknown type
      # skip this check (Guard 3 already handles unknown types).
      condition = (
        each.value.efa_interface_count < 0 ||
        each.value.efa_interface_count <= try(local.efa_capability[local.pool_rep_instance_type[each.key]].cards, 999999)
      )
      error_message = "Pool ${each.key} sets efa_interface_count = ${each.value.efa_interface_count}, but ${local.pool_rep_instance_type[each.key]} has only ${try(local.efa_capability[local.pool_rep_instance_type[each.key]].cards, 0)} EFA card(s). Reduce efa_interface_count to at most the card count, or leave it unset to auto-derive."
    }
  }

  # Discovered live: EC2NodeClass carries a karpenter.k8s.aws/termination finalizer that only
  # the Karpenter controller can clear — kubectl_manifest reports this "destroyed" the moment
  # the delete is accepted, same as the NodePool/NodeClaim issue null_resource.wait_for_node_drain
  # exists for (see the comment there). Without this edge, this EC2NodeClass's destroy runs
  # concurrently with the drain-wait instead of before it, and if helm_release.karpenter
  # finishes destroying first, the finalizer is never cleared and the object (and the
  # karpenter-crd chart's own destroy, which waits on its CRDs having no instances) hangs
  # forever. depends_on the same resource the NodePool manifests do, for the same reason: it
  # forces this destroy to be issued before the drain-wait resource, and the drain-wait
  # resource is destroyed before Karpenter — see karpenter.tf.
  depends_on = [helm_release.karpenter, null_resource.wait_for_node_drain]
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
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = each.key
          }
          # Taint every accelerator node so only pods that explicitly tolerate the
          # accelerator land here. Without this, arbitrary CPU workloads (coredns replicas,
          # controllers, a Ray head, a data-prep pod) schedule onto an idle GPU/Neuron node
          # and keep consolidationPolicy: WhenEmpty from ever firing — a multi-dollar-per-hour
          # node bills indefinitely while "not empty". NEITHER the NVIDIA nor the Neuron
          # device plugin taints the node (a common myth; GPU Operator does not either), so
          # the NodePool must do it. gpu-addons.tf/neuron-addons.tf install the plugins with a
          # matching toleration, and the workload manifests already tolerate nvidia.com/gpu.
          # (Capacity Block nodes ALSO carry a per-reservation `capacity-reservation` taint;
          # pods tolerate that with operator: Exists separately.)
          taints = [{
            key    = each.value.device_plugin == "neuron" ? "aws.amazon.com/neuron" : "nvidia.com/gpu"
            effect = "NoSchedule"
          }]
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
              values   = each.value.instance_types
            },
            {
              # Pin every pool to its single AZ. EFA/RDMA traffic is not routable across
              # subnets, so all ranks of a multi-node collective must share one AZ; Capacity
              # Block is single-AZ regardless. We deliberately do NOT spread on-demand/spot
              # pools across AZs — cross-AZ placement would silently break multi-node EFA
              # (NCCL falls back to TCP or fails) and cross-AZ FSx/traffic. If an AZ is
              # capacity-exhausted, prefer changing `zone` or using a Capacity Block.
              #
              # RESERVED pools: `zone` MUST equal the AZ where the Capacity Block was granted
              # (a CB cannot choose its AZ). If they disagree, this zone requirement and the
              # NodeClass's capacityReservationSelectorTerms contradict and NO node is ever
              # launched — the only signal is a Karpenter event. Check the reservation's AZ
              # with: aws ec2 describe-capacity-reservations --capacity-reservation-ids <id>
              # --query 'CapacityReservations[0].AvailabilityZone'. (The AWS Terraform provider
              # has no capacity-reservation data source, so this cannot be enforced at plan
              # time; it is a hard operational requirement.)
              key      = "topology.kubernetes.io/zone"
              operator = "In"
              values   = [each.value.zone]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = [each.value.arch]
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
        # Consolidate only empty nodes. consolidateAfter is per-pool (local.pool_consolidate_after):
        # reserved pools keep nodes ("Never") for the reservation window; on-demand/spot empty
        # nodes scale down after a short idle so an idle GPU pool does not bill indefinitely.
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = local.pool_consolidate_after[each.key]
        # Drift is enabled by default in Karpenter v1 and fires INDEPENDENTLY of
        # consolidationPolicy: a new "al2023@latest" AMI release marks a live node Drifted and
        # Karpenter replaces it — mid-training — even with expireAfter/consolidateAfter =
        # "Never". For reserved (Capacity Block = multi-hour/day training) pools that is data
        # loss, so pin the disruption budget to zero nodes: nothing is voluntarily disrupted for
        # the reservation window. (Blocking WhenEmpty consolidation too is harmless — the CB is
        # prepaid. A reason-scoped budget of ["Drifted"] would be more surgical but makes the
        # two conditional branches different object types, which Terraform rejects.) On-demand/
        # spot pools keep the default 10% budget so idle-scaledown and AMI patching still work; a
        # long training job on those pools should set karpenter.sh/do-not-disrupt on its pods
        # (see README) since this module cannot know which on-demand pools run long jobs.
        budgets = each.value.capacity_type == "reserved" ? [{ nodes = "0" }] : [{ nodes = "10%" }]
      }
      limits = {
        cpu    = each.value.cpu_limit
        memory = each.value.memory_limit
      }
    }
  })

  # Create-time this only needs accelerator_nodeclass. null_resource.wait_for_node_drain
  # (karpenter.tf) is added here purely for DESTROY ordering: Terraform destroys in the
  # reverse of depends_on order, so this makes the NodePool delete get issued BEFORE that
  # resource's destroy-time provisioner starts polling for NodeClaims to drain — which in
  # turn (via that resource's own depends_on) runs before Karpenter/its addons are removed.
  depends_on = [
    kubectl_manifest.accelerator_nodeclass,
    null_resource.wait_for_node_drain,
  ]
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

  # See the identical comment on kubectl_manifest.accelerator_nodeclass above.
  depends_on = [helm_release.karpenter, null_resource.wait_for_node_drain]
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

  # See the identical comment on kubectl_manifest.accelerator_nodepool above — this edge is
  # for destroy ordering only (issue the CPU NodePool delete before the drain-wait starts).
  depends_on = [
    kubectl_manifest.ec2nodeclass_cpu,
    null_resource.wait_for_node_drain,
  ]
}
