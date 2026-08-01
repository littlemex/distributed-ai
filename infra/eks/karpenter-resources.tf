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

# ── EFA capability lookup (dynamic, from EC2 API) ─────────────────────────────
# One data source per DISTINCT instance type across all pools. Replaces the former static
# efa_capability table: new instance generations are automatically correct without any code
# change. The two fields consumed by locals.tf pool_efa are efa_supported (bool) and
# efa_maximum_interfaces (number). Plan time only — no state stored, no cost.
data "aws_ec2_instance_type" "pool_rep" {
  for_each      = toset(flatten([for p in var.accelerator_pools : p.instance_types]))
  instance_type = each.value
}

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

  # ── ADR D6: disruption preset → concrete knobs ───────────────────────────────
  # A single table maps each preset to the two NodePool disruption knobs, so the D6 precedence (raw
  # override > preset > interruptible > derived) resolves to ONE lookup per knob. The pre-table code
  # let pool_consolidate_after key off has_reserved while pool_disruption_budget keyed off the preset
  # — the two DISAGREED for an EFA-derived on-demand pool (preset=protect but consolidate=5m). Both
  # now read this table, so they can never diverge. accelerator pools keep consolidationPolicy
  # "WhenEmpty" in BOTH presets (NOT WhenEmptyOrUnderutilized): a half-idle multi-GPU node is still
  # working, so only a truly EMPTY node may scale down — "underutilized" consolidation would evict
  # live training nodes (this is why ADR D6's generic reclaim="WhenEmptyOrUnderutilized"/"30s" does
  # NOT apply to accelerator pools; that value is for the CPU pool, see docs/adr-0001 D6).
  # Legacy parity: protect == the old reserved branch ("Never"/"0"), reclaim == the old
  # on-demand/spot branch ("5m"/"10%"). ONE intentional legacy change: an EFA-enabled ON-DEMAND pool
  # now derives protect (efa>0 → protect, ADR D6), moving its budget/consolidate 10%/5m → 0/Never —
  # correct for an EFA collective (any voluntary disruption kills every rank) and inert for the
  # current tfvars (gpu-dev has efa=0 → reclaim, unchanged).
  disruption_presets = {
    protect = { consolidate_after = "Never", budget_nodes = "0" }
    reclaim = { consolidate_after = "5m", budget_nodes = "10%" }
  }

  # Per-pool consolidateAfter: an explicit pool.consolidate_after override wins, else the preset.
  pool_consolidate_after = {
    for k, p in var.accelerator_pools : k => (
      p.consolidate_after != "" ? p.consolidate_after :
      local.disruption_presets[local.pool_disruption_preset[k]].consolidate_after
    )
  }

  # ── Rendered capacity-mix values (ADR 0001, Phase 3) ─────────────────────────
  # These translate the normalized pool_effective view (locals.tf) into the exact shapes the
  # NodePool/EC2NodeClass bodies below embed. Each is written so a LEGACY-form pool (single
  # capacity_type / cb_reservation_id / zone) renders byte-for-byte what the pre-Phase-3 code did,
  # while a NEW-form pool gains the list/multi-reservation/multi-AZ/preset behavior.

  # capacityReservationSelectorTerms: one {id=...} term per reservation id, plus a single {tags=...}
  # term when tag-based selection is used. Only consumed when has_reserved is true (a validation in
  # variables.tf guarantees has_reserved ⇒ at least one id or a non-empty tags map, so this is never
  # the empty list the Karpenter v1 CRD rejects). Legacy reserved pool → [{id = cb_reservation_id}].
  pool_capacity_reservation_terms = {
    for k, n in local.pool_effective : k => concat(
      [for id in n.reservation_ids : { id = id }],
      length(n.reservation_tags) > 0 ? [{ tags = n.reservation_tags }] : []
    )
  }

  # Zone requirement values (topology.kubernetes.io/zone In [...]). When a pool sets an explicit
  # zones list (ADR D4), "*" expands to every cluster AZ and any other list is used verbatim
  # (multi-AZ inference). When zones is unset (the legacy case), fall back to the single
  # local.pool_zone[k] derivation (explicit pool.zone → reserved CB AZ → azs[0]) so existing tfvars
  # render an identical one-element list. NOTE: new-form reserved pools that need the CB's AZ
  # auto-resolved must use the legacy cb_reservation_id (which capacity-block.tf describes) or set
  # zones explicitly — capacity_reservations{ids,tags} are NOT zone-resolved (see docs/adr-0001).
  pool_zone_requirement_values = {
    for k, n in local.pool_effective : k => (
      length(n.zones) > 0
      ? (contains(n.zones, "*") ? local.azs : n.zones)
      : [local.pool_zone[k]]
    )
  }

  # Per-pool disruption budget nodes value: an explicit disruption_budget_nodes override wins, else
  # the SAME preset table pool_consolidate_after uses (so budget and consolidateAfter can never
  # disagree). protect → "0" (nothing voluntarily disrupted — protects a reservation window or an EFA
  # collective from Drift/consolidation mid-run); reclaim → "10%" (idle scaledown and AMI patching
  # still work). Legacy reserved → protect → "0"; legacy on-demand (efa=0) → reclaim → "10%".
  pool_disruption_budget_nodes = {
    for k, p in var.accelerator_pools : k => (
      p.disruption_budget_nodes != null ? p.disruption_budget_nodes :
      local.disruption_presets[local.pool_disruption_preset[k]].budget_nodes
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
# VERIFIED that the EC2NodeClass v1 CRD accepts placementGroupSelector (it is NOT pruned):
# on the live cluster `kubectl get ec2nodeclass -o yaml` shows a `PlacementGroupReady: True`
# status condition on the applied NodeClass. If you bump the Karpenter version, re-check
# with a server-side dry-run so a schema change can't silently prune the field into a no-op.
# Note: a placement group cannot be deleted while instances are still in it, so a pool
# teardown must drain nodes first. The EC2NodeClass -> PG name reference only gives an
# IMPLICIT create-order edge; on destroy, PG deletion could otherwise race the drain and
# DeletePlacementGroup would fail while instances remain. The ordering is enforced the same
# way sg.tf orders aws_security_group.efa_node: null_resource.wait_for_node_drain
# depends_on THIS resource (see karpenter.tf), so on destroy the drain-wait runs first and
# the PG is deleted only after the nodes are gone. Do NOT add depends_on here (that would
# reverse the destroy order and delete the PG before the drain).
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
      # Reserved pools name their Capacity Block(s) here. Keyed on the normalized has_reserved so a
      # mixed reserved+spot pool (Intent M) still gets the selector; the terms come from
      # pool_capacity_reservation_terms (one {id} per reservation id ∪ a {tags} term), which for a
      # legacy pool is exactly [{id = cb_reservation_id}]. Omitted entirely for a pure on-demand/spot
      # pool — the Karpenter v1 CRD rejects an empty [] ("'id' is mutually exclusive").
      local.pool_effective[each.key].has_reserved ? {
        capacityReservationSelectorTerms = local.pool_capacity_reservation_terms[each.key]
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
    # networkInterfaces layout is rendered for the whole pool. EFA topology is resolved from the
    # EC2 API (data.aws_ec2_instance_type.pool_rep) at plan time — no static table to maintain.
    precondition {
      condition = length(distinct([
        for t in each.value.instance_types :
        format("%d/%s",
          data.aws_ec2_instance_type.pool_rep[t].efa_supported ? coalesce(data.aws_ec2_instance_type.pool_rep[t].efa_maximum_interfaces, 0) : 0,
          data.aws_ec2_instance_type.pool_rep[t].efa_supported && coalesce(data.aws_ec2_instance_type.pool_rep[t].efa_maximum_interfaces, 0) > 1)
      ])) == 1
      error_message = "Pool ${each.key} mixes instance types with different EFA topologies (${join(", ", each.value.instance_types)}). All instance_types in a pool must share the same EFA card count and multi-card layout."
    }
    # Guard 2: a multi-card EFA instance must not resolve to a single-card layout via override.
    precondition {
      condition = (
        local.pool_efa[each.key].count == 0 ||
        !(
          (data.aws_ec2_instance_type.pool_rep[local.pool_rep_instance_type[each.key]].efa_supported &&
           coalesce(data.aws_ec2_instance_type.pool_rep[local.pool_rep_instance_type[each.key]].efa_maximum_interfaces, 0) > 1) &&
          (local.pool_efa[each.key].count <= 1 || !local.pool_efa[each.key].multi_card)
        )
      )
      error_message = "Pool ${each.key} (${local.pool_rep_instance_type[each.key]}) is a multi-card EFA instance but resolved to a single-card layout. Leave efa_interface_count/efa_multi_card unset to auto-derive, set efa_multi_card = true with the correct count, or set efa_interface_count = 0 to disable EFA."
    }
    # (Guard 3 removed: with the EC2 API data source, there is no "unknown type" — every type
    # the pool lists is queried at plan time and its EFA capability is always known.)
    # Guard 4: a manual efa_interface_count override must not exceed the instance's physical
    # card count. Over-counting makes Karpenter render networkInterfaces with cards that do not
    # exist; RunInstances fails and Karpenter retries in a loop.
    precondition {
      condition = (
        each.value.efa_interface_count < 0 ||
        each.value.efa_interface_count <= coalesce(data.aws_ec2_instance_type.pool_rep[local.pool_rep_instance_type[each.key]].efa_maximum_interfaces, 0)
      )
      error_message = "Pool ${each.key} sets efa_interface_count = ${each.value.efa_interface_count}, but ${local.pool_rep_instance_type[each.key]} has only ${coalesce(data.aws_ec2_instance_type.pool_rep[local.pool_rep_instance_type[each.key]].efa_maximum_interfaces, 0)} network card(s). Reduce efa_interface_count to at most the card count, or leave it unset to auto-derive."
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
          # The two module-owned labels are the stable API pods select on (node-role = pool name,
          # per ADR D11; device = which device plugin tolerates this node). User-supplied labels
          # (pool.labels, default {}) merge ON TOP for finer placement (e.g. workload=training).
          # An empty map leaves this byte-identical to the pre-Phase-3 output. Module labels are
          # listed last so a pool cannot accidentally override node-role / distributed-ai/device.
          labels = merge(each.value.labels, {
            "node-role"             = each.key
            "distributed-ai/device" = each.value.device_plugin # "nvidia" | "neuron"
          })
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
          #
          # The module-owned device-plugin taint always comes first; user-supplied taints
          # (pool.taints, default []) are appended for extra isolation (e.g. a dedicated team taint).
          # A taint's `value` is optional — omit the key entirely when unset rather than emitting
          # value: null, which yamlencode would render as `value: null` and change the manifest.
          # An empty user list leaves this byte-identical to the pre-Phase-3 single-taint output.
          taints = concat(
            [{
              key    = each.value.device_plugin == "neuron" ? "aws.amazon.com/neuron" : "nvidia.com/gpu"
              effect = "NoSchedule"
            }],
            [for t in each.value.taints : merge(
              { key = t.key, effect = t.effect },
              t.value != null ? { value = t.value } : {}
            )]
          )
          requirements = [
            {
              # reserved (Capacity Block) | on-demand | spot — one or more. Karpenter's native
              # priority orders reserved → spot → on-demand within this set (Intent F, fallback to
              # meet node count). A legacy single capacity_type renders a one-element list identical
              # to the pre-Phase-3 output. NOTE (Intent M — deliberate reserved+spot coexistence):
              # listing both here lets Karpenter run baseline reserved + burst spot concurrently, but
              # because reserved is price=0 Karpenter would consolidate spot ONTO reserved; a pod that
              # must stay on spot pins itself with nodeSelector karpenter.sh/capacity-type: spot (see
              # docs/adr-0001 D2 and the book's Intent F/M chapter). The pool only supplies the set.
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = local.pool_effective[each.key].capacity_types
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
              # RESERVED pools: the resolved zone (local.pool_zone) is READ FROM the Capacity
              # Block reservation (capacity-block.tf → local.pool_cb_zone), so it can never
              # disagree with the AZ where the CB was granted — a CB moving AZ only needs its
              # new cb_reservation_id, no zone edit. on-demand/spot pools resolve to azs[0]
              # unless pool.zone is set explicitly. az.tf asserts the resolved zone is one of
              # the cluster AZs, so this requirement can never point Karpenter at a
              # subnet-less zone.
              #
              # MULTI-AZ (ADR D4): pool_zone_requirement_values expands an explicit `zones` list ("*" → all
              # cluster AZs) so a loosely-coupled inference pool can spread g6 across AZs (the pod
              # adds topologySpreadConstraints). A pool that leaves zones unset renders exactly
              # [local.pool_zone[k]] — one element, byte-identical to the pre-Phase-3 output. A
              # variable validation (variables.tf) forbids EFA + multi-AZ, so an EFA/RDMA pool can
              # never reach here with more than one zone (EFA is not routable across subnets).
              key      = "topology.kubernetes.io/zone"
              operator = "In"
              values   = local.pool_zone_requirement_values[each.key]
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
          # Upper bound on graceful drain. karpenter.sh/do-not-disrupt (set on training pods to
          # survive consolidation) also blocks the drain when a NodeClaim is finally deleted; a
          # pod stuck Terminating (e.g. a wedged TrainJob worker) could otherwise pin the node —
          # and its GPU/Neuron billing — indefinitely. This caps that: after the window Karpenter
          # force-terminates regardless. Long enough (1h) for a real checkpoint-on-SIGTERM to
          # finish, short enough that a hung pod cannot hold an accelerator node forever.
          terminationGracePeriod = each.value.termination_grace_period
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
        #
        # Phase 3: the "0" vs "10%" choice now comes from pool_disruption_budget, which resolves
        # the 2-layer disruption preset (ADR D6): an explicit disruption_budget_nodes wins, else the
        # preset ("protect" → "0", "reclaim" → "10%"), where the preset itself defaults to "protect"
        # for a reserved-or-EFA pool and "reclaim" otherwise. A legacy reserved pool → "0" and a
        # legacy on-demand pool (efa=0) → "10%", byte-identical to the previous
        # `capacity_type == "reserved" ? "0" : "10%"`.
        budgets = [{ nodes = local.pool_disruption_budget_nodes[each.key] }]
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

# ── WARN: reserved+spot in one pool is a synchronous-collective footgun (ADR D2/D11, R9) ──────
# A pool that lists BOTH "reserved" and "spot" is a deliberately supported shape (Intent M — a
# reserved baseline with spot burst, ADR D1). It is NOT an error, so this is a `check` WARNING, not a
# validation: it warns on every plan/apply but never blocks one. The hazard it surfaces: if a single
# tightly-coupled job (multi-node NCCL/all-reduce training — one world where every rank must stay up)
# is scheduled across such a pool, a single spot reclaim tears down a rank and the entire collective
# dies, wasting the reserved capacity too (and the work since the last checkpoint). The module cannot
# see which workloads land on a pool, so it cannot gate this — it can only remind the operator that a
# synchronous collective on a reserved+spot pool MUST pin its ranks to the reserved capacity via
# nodeSelector karpenter.sh/capacity-type: reserved (see the book's Intent F/M chapter and ADR D2),
# leaving spot for restart-tolerant work (inference, data prep, async RL rollouts).
check "reserved_spot_mix_is_collective_footgun" {
  assert {
    condition = alltrue([
      for k, n in local.pool_effective :
      !(contains(n.capacity_types, "reserved") && contains(n.capacity_types, "spot"))
    ])
    error_message = "Pool(s) mix \"reserved\" and \"spot\" in one capacity_types list: ${jsonencode({ for k, n in local.pool_effective : k => n.capacity_types if contains(n.capacity_types, "reserved") && contains(n.capacity_types, "spot") })}. This is supported (Intent M: reserved baseline + spot burst), but a SYNCHRONOUS collective (multi-node NCCL training) placed here will lose the whole world when a single spot node is reclaimed. Pin such a job's ranks with nodeSelector karpenter.sh/capacity-type: reserved, and leave spot for restart-tolerant work. Ignore this warning if the pool only runs interruptible workloads."
  }
}
