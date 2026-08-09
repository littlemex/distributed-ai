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
#                        instance type (EC2 API at plan time). Set explicitly to override;
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
#   termination_grace_period  NodePool terminationGracePeriod (Go duration); caps graceful drain.
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
    # capacity_type (LEGACY, single value): "reserved" | "on-demand" | "spot". Retained for
    # backward compatibility and mapped to [capacity_type]. Use capacity_types (plural) for new
    # pools. Setting both is a validation error. See docs/adr-0001-accelerator-pools-mixing.md.
    capacity_type = optional(string)
    # capacity_types (NEW, list): any subset of ["reserved","on-demand","spot"]. Karpenter
    # natively prioritises reserved → spot → on-demand and falls back to meet the node count
    # (Intent F). Deliberate simultaneous coexistence (Intent M) is expressed by pinning pods to
    # a capacity-type via nodeSelector — NOT by a schema field (ADR D2). Unset → derived from the
    # legacy capacity_type, else ["on-demand"]. (Phase 1: normalized in locals, not yet rendered.)
    capacity_types = optional(list(string))
    # Single AZ to pin to. "" (default) = derive: reserved → CB's AZ, on-demand/spot → azs[0].
    # Set an explicit AZ (one of local.azs) only to override that default. (LEGACY single-AZ knob;
    # zones (plural) is the new first-class axis — see below.)
    zone = optional(string, "")
    # zones (NEW, list): [] / unset → derive [azs[0]] (single AZ, co-located with FSx). One element
    # = single AZ; several = spread across listed AZs; ["*"] = all cluster AZs (multi-AZ opt-in,
    # ADR D4). Fallback (capacity_types) does NOT imply AZ spread — orthogonal axes. EFA/reserved
    # pools are forced single-AZ (validated in Phase 2). (Phase 1: normalized in locals, not yet rendered.)
    zones = optional(list(string))
    # EFA topology is derived from the instance type (EC2 API at plan time) unless
    # set explicitly. Leave efa_interface_count = -1 (default) and efa_multi_card = null
    # to auto-derive; set a value to override. 0 disables EFA.
    efa_interface_count = optional(number, -1)
    efa_multi_card      = optional(bool, null)
    # Capacity Block: cb_reservation_id (cr-...) is required for capacity_type "reserved".
    # cb_end_date (RFC3339) optionally schedules a pre-expiry alert for THIS pool.
    # (LEGACY single reservation; capacity_reservations (below) is the new multi-reservation form.)
    cb_reservation_id = optional(string, "")
    cb_end_date       = optional(string, "")
    # capacity_reservations (NEW): select MULTIPLE reservations (Capacity Blocks / ODCRs) by id
    # list and/or tag map. Rendered into capacityReservationSelectorTerms only when the pool
    # includes "reserved". Karpenter does NOT auto-discover open reservations — every reservation
    # used must be listed here (ADR D3). ids each become one selector term; tags (max 20 keys)
    # become one term; terms are OR-combined. Legacy cb_reservation_id normalizes into ids.
    # (Phase 1: normalized in locals, not yet rendered.)
    capacity_reservations = optional(object({
      ids  = optional(list(string), [])
      tags = optional(map(string), {})
    }))
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
    # termination_grace_period: Go duration. Upper bound on graceful drain when a NodeClaim is
    # deleted — caps how long a do-not-disrupt / stuck-Terminating pod can pin an accelerator node
    # (and its billing). 1h leaves room for checkpoint-on-SIGTERM without stranding a hung pod.
    termination_grace_period = optional(string, "1h")
    # consolidate_after: Go duration ("5m") or "Never". Karpenter scales an empty node
    # down after this idle period. OVERRIDE knob: when set (non-"") it wins over the disruption
    # preset and the per-capacity_type default (ADR D6 precedence: raw field > disruption preset >
    # interruptible > derived). Unset ("") → preset/derived.
    consolidate_after = optional(string, "")
    # disruption (NEW preset, ADR D6): "protect" | "reclaim" | unset.
    #   protect = WhenEmpty + consolidateAfter "Never" + budget "0" (running jobs never voluntarily
    #             disrupted — training / reserved).
    #   reclaim = WhenEmptyOrUnderutilized + "30s"/"5m" + budget "10%" (idle nodes reclaimed —
    #             inference / verification).
    # Unset → derived: efa_interface_count > 0 OR capacity_reservations non-empty → protect, else
    # reclaim. Per-pod exceptions use karpenter.sh/do-not-disrupt. (Phase 1: normalized, not rendered.)
    disruption = optional(string)
    # disruption_budget_nodes (NEW override): NodePool disruption budget nodes value (e.g. "10%",
    # "0"). Non-null overrides the disruption preset (ADR D6). Unset → preset/derived.
    disruption_budget_nodes = optional(string)
    # interruptible (DEPRECATED, ADR D6): bool mapped to disruption (true → reclaim, false →
    # protect). Setting it together with disruption is a validation error. Prefer disruption.
    interruptible = optional(bool)
    cpu_limit     = optional(string, "10000")
    memory_limit  = optional(string, "100000Gi")
    # labels: extra node labels merged onto this pool's nodes (team/workload routing). Pods target
    # a pool by node-role=<pool-name> (the stable API, ADR D11); these are for finer routing.
    # (Phase 1: passthrough field, not yet rendered.)
    labels = optional(map(string), {})
    # taints: extra node taints. GPU/Neuron device-plugin taints are applied automatically; use
    # this for additional pool-dedication taints. (Phase 1: passthrough field, not yet rendered.)
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })), [])
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
  # capacity_type (legacy single) and capacity_types (new list) are mutually exclusive; set one.
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      !(p.capacity_type != null && p.capacity_types != null)
    ])
    error_message = "Set either capacity_type (legacy single) OR capacity_types (list), not both. Prefer capacity_types for new pools."
  }
  # zone (legacy single) and zones (new list) are mutually exclusive — the SAME asymmetry the
  # capacity_type/capacity_types check above prevents. pool_effective derives zones with `p.zones != null
  # ? p.zones : p.zone != "" ? [p.zone] : []`, so if BOTH are set the new zones SILENTLY WINS and the
  # legacy zone is dropped — the "I edited zone but the AZ didn't change" trap. Fail loudly instead.
  # zone defaults to "" (unset) and zones to null (unset); a collision is zone != "" AND zones != null.
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      !(p.zone != "" && p.zones != null)
    ])
    error_message = "Set either zone (legacy single AZ) OR zones (list), not both — the new zones list would silently override the legacy zone. Prefer zones for new pools; use zone only in the legacy single-AZ form."
  }
  # Legacy capacity_type, when set, must be one of the three values.
  # NULL-SAFETY via ternary (NOT coalesce): the earlier coalesce(p.capacity_type, "on-demand")
  # SILENTLY ADMITTED capacity_type = "" — coalesce treats "" as an empty/invalid value and skips
  # to the "on-demand" sentinel, so the membership check passed, yet pool_effective (which gates on
  # `!= null`, and "" is not null) then rendered capacity_types = [""] into the NodePool's
  # capacity-type requirement values, breaking scheduling only AFTER apply. The ternary admits a
  # genuine unset (null) but forces a set-but-empty "" to fail the membership check at plan time.
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      p.capacity_type == null ? true : contains(["reserved", "on-demand", "spot"], p.capacity_type)
    ])
    error_message = "Each accelerator pool's capacity_type must be \"reserved\", \"on-demand\", or \"spot\" (an empty string is not valid — leave it unset to default to on-demand)."
  }
  # capacity_types, when set, must be a non-empty subset of the three values with no duplicates.
  # NULL-SAFETY: a ternary (which DOES short-circuit) gates the length()/distinct()/alltrue() calls.
  # `p.capacity_types == null || (...)` would NOT short-circuit — HCL evaluates both sides of ||, so
  # length(null) would error for every legacy/unset pool.
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      p.capacity_types == null ? true : (
        length(p.capacity_types) > 0 &&
        length(p.capacity_types) == length(distinct(p.capacity_types)) &&
        alltrue([for ct in p.capacity_types : contains(["reserved", "on-demand", "spot"], ct)])
      )
    ])
    error_message = "capacity_types must be a non-empty list of distinct values drawn from \"reserved\", \"on-demand\", \"spot\"."
  }
  # NOTE: "zone must be one of the resolved AZs" is NOT validated here — the resolved AZ list
  # (local.azs) comes from a data source, which a variable validation block cannot reference.
  # It is enforced as a precondition in az.tf (terraform_data.az_invariants) instead.
  # A pool that includes "reserved" (via legacy capacity_type OR new capacity_types) must name at
  # least one reservation, since Karpenter does not auto-discover open reservations (ADR D3). The
  # reservation may come from legacy cb_reservation_id OR new capacity_reservations{ids|tags}.
  # NULL-SAFETY: == / != are null-safe (null == "reserved" is false), so legacy capacity_type and
  # cb_reservation_id are compared directly — NO coalesce (coalesce REJECTS "" as a fallback, so
  # coalesce(p.capacity_type, "") errors when both are null/empty). The capacity_types membership
  # is guarded by a ternary (which DOES short-circuit) so contains() never receives null. try(...)
  # reads attributes off capacity_reservations only when it is non-null.
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      !(p.capacity_type == "reserved" || (p.capacity_types != null ? contains(p.capacity_types, "reserved") : false)) ||
      (p.cb_reservation_id != null && p.cb_reservation_id != "") ||
      length(try(p.capacity_reservations.ids, [])) > 0 ||
      length(try(p.capacity_reservations.tags, {})) > 0
    ])
    error_message = "A pool that includes \"reserved\" must name a reservation: set capacity_reservations = { ids = [...] } (or tags), or the legacy cb_reservation_id (cr-...)."
  }
  # Every reservation id (legacy cb_reservation_id ∪ new capacity_reservations.ids) must look like a
  # real reservation id ("cr-" + hex). Karpenter's capacityReservationSelectorTerms does NOT validate
  # the id shape: a typo, an empty string, or an ODCR-style "cr_" underscore is accepted into the CRD
  # and then simply matches no offering — the reserved node never launches and the pod Pends forever,
  # visible only in the Karpenter event log. Catch it at plan time. A non-"reserved" pool cannot reach
  # here with a reservation set (the two validations above forbid that), and an empty cb_reservation_id
  # on a non-reserved pool is the unset default, so filter it out before the regex.
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      alltrue([
        for id in concat(
          try(p.capacity_reservations.ids, []),
          (p.cb_reservation_id != null && p.cb_reservation_id != "") ? [p.cb_reservation_id] : []
        ) : can(regex("^cr-[0-9a-f]+$", id))
      ])
    ])
    error_message = "A reservation id must be a Capacity Block / ODCR id of the form \"cr-\" followed by hex (e.g. \"cr-0123456789abcdef0\"). Check capacity_reservations.ids and cb_reservation_id for typos, empty strings, or wrong separators."
  }
  # capacity_reservations / cb_reservation_id must NOT be set on a pool that does not include
  # "reserved" — otherwise the reservation is silently ignored and the pool bills on-demand/spot.
  # NULL-SAFETY: same rules as above — direct == for null-safe fields, ternary-guarded contains for
  # the capacity_types list, and cb_reservation_id (which defaults to "") tested with a plain ==.
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      (p.capacity_type == "reserved" || (p.capacity_types != null ? contains(p.capacity_types, "reserved") : false)) ||
      ((p.cb_reservation_id == null || p.cb_reservation_id == "") && p.capacity_reservations == null)
    ])
    error_message = "A pool sets a reservation (capacity_reservations or cb_reservation_id) but does not include \"reserved\" in its capacity type(s); the reservation would be ignored. Add \"reserved\", or clear the reservation."
  }
  # A NEW-form reserved pool (capacity_types includes "reserved", as opposed to the legacy scalar
  # capacity_type = "reserved") MUST name its zone explicitly. Capacity Block AZ auto-resolution
  # (capacity-block.tf → local.pool_cb_zone → az.tf local.pool_zone) keys off the LEGACY
  # capacity_type == "reserved" path ONLY, so a new-form reserved pool that omits zones falls back to
  # azs[0]; if its CB is in another AZ the NodePool's zone requirement contradicts the reservation's
  # AZ and Karpenter can never launch a node (silent, Karpenter-event-log-only Pending). ADR D4 says
  # "new-form reserved must set zones explicitly (capacity_reservations are NOT zone-auto-resolved)";
  # this enforces it. Legacy reserved (capacity_type == "reserved" + cb_reservation_id) is exempt —
  # it auto-resolves the AZ from the reservation. The `? : false` guards contains() against a null
  # capacity_types (|| does not short-circuit); == "" / == null are null-safe.
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      !(
        (p.capacity_types != null ? contains(p.capacity_types, "reserved") : false) &&
        p.zones == null &&
        p.zone == ""
      )
    ])
    error_message = "A pool that includes \"reserved\" via capacity_types must set zones explicitly (e.g. zones = [\"us-west-2a\"]) so its single AZ matches the Capacity Block — capacity_reservations are NOT zone-auto-resolved. Set zones, or use the legacy capacity_type = \"reserved\" + cb_reservation_id form (which reads the AZ from the reservation)."
  }
  # interruptible (deprecated) and disruption (preset) are mutually exclusive — no implicit winner.
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      !(p.interruptible != null && p.disruption != null)
    ])
    error_message = "Set either disruption (\"protect\"/\"reclaim\") OR the deprecated interruptible bool, not both."
  }
  # disruption, when set, must be a known preset. NULL-SAFETY via ternary (NOT coalesce): the earlier
  # coalesce(p.disruption, "reclaim") SILENTLY ADMITTED disruption = "" (coalesce skips "" to the
  # sentinel), yet locals gates disruption_preset on `p.disruption != null` — and "" is not null — so
  # the preset would resolve to "" and local.disruption_presets[""] raises "Invalid index" at plan
  # time (or worse, a future non-table consumer silently mis-defaults). The ternary admits a genuine
  # unset (null → derived) but forces a set-but-empty "" to fail here.
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      p.disruption == null ? true : contains(["protect", "reclaim"], p.disruption)
    ])
    error_message = "disruption must be \"protect\", \"reclaim\", or unset (derived) — an empty string is not valid."
  }
  # capacity_reservations.tags is limited to 20 keys (EC2 capacityReservationSelectorTerms limit).
  # try(...) reads .tags only when capacity_reservations is non-null.
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      length(try(p.capacity_reservations.tags, {})) <= 20
    ])
    error_message = "capacity_reservations.tags is limited to 20 keys (EC2 selector-term limit)."
  }
  # A user taint's effect must be one of the three Kubernetes values, or the NodePool is rejected at
  # apply time by Karpenter admission (a plan-time-catchable error otherwise surfacing only mid-apply).
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      alltrue([for t in p.taints : contains(["NoSchedule", "PreferNoSchedule", "NoExecute"], t.effect)])
    ])
    error_message = "Each taint effect must be \"NoSchedule\", \"PreferNoSchedule\", or \"NoExecute\"."
  }
  # A user taint must not reuse the module-owned device-plugin taint key (nvidia.com/gpu for an
  # nvidia pool, aws.amazon.com/neuron for a neuron pool). karpenter-resources.tf ALWAYS renders that
  # taint first; a user taint with the same key produces two taints sharing a key+effect, which the
  # kubelet rejects on node registration — Karpenter then loops launching-and-failing and every pod
  # targeting the pool Pends forever. The device plugin's own toleration already covers the module
  # taint, so re-declaring it is never needed.
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      alltrue([for t in p.taints :
        t.key != (p.device_plugin == "neuron" ? "aws.amazon.com/neuron" : "nvidia.com/gpu")
      ])
    ])
    error_message = "A pool taint reuses the module-owned device-plugin taint key (nvidia.com/gpu or aws.amazon.com/neuron). That taint is applied automatically; remove it from taints — a duplicate key+effect makes the kubelet reject node registration and pods Pend forever."
  }
  # User labels must not collide with the two module-owned labels (node-role = pool name, the stable
  # pod-selection API per ADR D11; distributed-ai/device = which device plugin tolerates the node).
  # merge() renders module labels LAST so a collision is silently overridden, but silently dropping a
  # user's label is worse than telling them — a user who sets node-role expecting it to take effect
  # would be confused when pods still select the pool name. Fail loudly instead.
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      !contains(keys(p.labels), "node-role") && !contains(keys(p.labels), "distributed-ai/device")
    ])
    error_message = "A pool's labels set a module-owned key (node-role or distributed-ai/device). node-role is the pool name (the stable pod-selection API) and distributed-ai/device is set from device_plugin; both are applied automatically. Remove them from labels."
  }
  # User labels must not live in a Karpenter/Kubernetes RESTRICTED label domain. Karpenter's NodePool
  # admission webhook rejects spec.template.metadata.labels whose key is (or is under) kubernetes.io,
  # k8s.io, karpenter.sh, or karpenter.k8s.aws — these are reserved for well-known labels Karpenter and
  # the kubelet own (e.g. topology.kubernetes.io/zone, karpenter.sh/capacity-type). A label like
  # "karpenter.sh/capacity-type" = "spot" here does NOT pin the pool — it makes the whole NodePool
  # apply fail admission, AFTER plan, mid-apply. Catch it at plan time. A key equals the domain (e.g.
  # "kubernetes.io") or has it as a "<domain>/..."-prefixed subdomain; a bare key like "workload" or a
  # non-reserved domain like "team.example.com/tier" passes.
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      alltrue([for key in keys(p.labels) :
        !anytrue([for d in ["kubernetes.io", "k8s.io", "karpenter.sh", "karpenter.k8s.aws"] :
          key == d || startswith(key, "${d}/") || endswith(split("/", key)[0], ".${d}")
        ])
      ])
    ])
    error_message = "A pool label uses a restricted domain (kubernetes.io, k8s.io, karpenter.sh, or karpenter.k8s.aws, including subdomains like topology.kubernetes.io). Karpenter's NodePool admission rejects these, failing the apply mid-way. Use an unreserved key (e.g. \"workload\", \"team.example.com/tier\") for pod routing; well-known labels like capacity-type/zone are set by the module's requirements, not here."
  }
  # EFA and multi-AZ are mutually exclusive: EFA/RDMA is not routable across subnets, so an
  # EFA-enabled pool must pin to a single AZ. A pool that explicitly enables EFA
  # (efa_interface_count > 0) must not request multiple zones (ADR D4/D5). NOTE: this checks the
  # EXPLICIT efa_interface_count only; derived-EFA (-1) + zones is caught by the az.tf precondition
  # once rendering is wired (Phase 3), where the resolved topology (local.pool_efa) is available.
  # length(coalesce(p.zones, [])) is null-safe: unset zones → [] → length 0 → passes.
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      p.efa_interface_count <= 0 || length(coalesce(p.zones, [])) <= 1
    ])
    error_message = "An EFA-enabled pool (efa_interface_count > 0) must pin to a single AZ — EFA/RDMA is not routable across subnets. Set zones to one AZ (or [] to derive azs[0]), or set efa_interface_count = 0."
  }
  # A reserved pool must pin to a SINGLE AZ. A Capacity Block lives in exactly one AZ, so a
  # multi-AZ zones list (several entries, or the "*" all-AZs wildcard) would make Karpenter try to
  # launch reserved nodes in an AZ the reservation does not cover — permanent Pending in every AZ
  # but the CB's. Applies to reserved via legacy capacity_type OR new capacity_types. Single-element
  # zones and unset zones (null → derive) pass; "*" is rejected because it expands to all cluster AZs.
  # NULL-SAFETY: two guards, because || does NOT short-circuit in HCL. (1) The `? : false` guards
  # contains() against a null capacity_types. (2) The `p.zones == null ? true : (...)` ternary guards
  # length()/contains() against a null zones. The earlier `p.zones == null || (length(p.zones)...)` was
  # WRONG: || still evaluated length(null)/contains(null,...) on every zones-unset pool — including the
  # legacy on-demand gpu-dev — raising "argument must not be null" at plan time (it slipped past because
  # `terraform validate` runs with the empty-map default, and the isolated console tests all set zones).
  validation {
    condition = alltrue([for k, p in var.accelerator_pools :
      !(p.capacity_type == "reserved" || (p.capacity_types != null ? contains(p.capacity_types, "reserved") : false)) ||
      (p.zones == null ? true : (length(p.zones) <= 1 && !contains(p.zones, "*")))
    ])
    error_message = "A reserved pool must pin to a single AZ — a Capacity Block lives in one AZ, so multi-AZ zones (several entries or \"*\") would leave reserved nodes permanently Pending outside the CB's AZ. Set zones to exactly one AZ (e.g. zones = [\"us-west-2a\"])."
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
    # Applies to a pool that includes "reserved" via legacy capacity_type OR new capacity_types.
    condition = alltrue([for k, p in var.accelerator_pools :
      p.placement_group_strategy == null ||
      !(p.capacity_type == "reserved" || (p.capacity_types != null ? contains(p.capacity_types, "reserved") : false))
    ])
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
  # (The former "cb_reservation_id on a non-reserved pool" check is now folded into the
  # reservation-requires-reserved validation above, which also covers capacity_reservations.)
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
    Whether the GPU Operator should build/load gdrdrv via its own gdrcopy component.
    This ONLY works when gpu_operator_install_driver = true: the operator implements
    gdrcopy as a sidecar container inside its driver DaemonSet, so with an
    AMI-preinstalled driver (install_driver = false) the driver DaemonSet — and thus
    the gdrcopy sidecar — never exists, and this flag is a no-op. To load gdrdrv on
    nodes that use the AMI's preinstalled driver, use var.gdrcopy_mode instead.
    gdrcopy is a small-message latency optimization; the bulk GPUDirect RDMA path
    (NIC DMA straight into GPU memory) does not depend on it.
  EOT
  type        = bool
  default     = false
}

variable "gdrcopy_mode" {
  description = <<-EOT
    How to load the gdrdrv kernel module on GPU nodes that use the AMI's preinstalled
    driver (the Capacity Block path, where gpu_operator_install_driver = false and the
    GPU Operator's own gdrcopy sidecar cannot run). AL2023 ships gdrcopy-kmod as a
    native dkms package plus a gdrcopy.service systemd unit that loads gdrdrv AFTER
    nvidia and recreates /dev/gdrdrv on every boot, so all we must do is install the
    package once. gdrcopy accelerates small-message receive copies over EFA; it is NOT
    required for the bulk GPUDirect RDMA path, which is already active.
      "off"       — do nothing (default). /dev/gdrdrv is absent; NCCL logs a benign
                    "Failed to initialize GDRCopy" and falls back to an EFA loopback copy.
      "userdata"  — RECOMMENDED. Install gdrcopy-kmod from the EC2NodeClass userData (a
                    cloud-init x-shellscript part merged before the nodeadm NodeConfig).
                    Applied only to nvidia GPU pools. Declarative, no standing pod; reboot
                    persistence is handled by gdrcopy.service. Requires a node roll to apply.
      "daemonset" — FALLBACK for when you cannot recycle nodes. A gdrdrv-loader DaemonSet
                    loads gdrdrv on already-running GPU nodes via a privileged initContainer
                    (the long-running pod is unprivileged). Prefer "userdata" for steady state.
    Only the AMI-driver path needs this; leave "off" once amazon-eks-ami loads gdrdrv itself.
  EOT
  type        = string
  default     = "off"
  validation {
    condition     = contains(["off", "userdata", "daemonset"], var.gdrcopy_mode)
    error_message = "gdrcopy_mode must be one of: off, userdata, daemonset."
  }
  # Single gdrdrv loader. gdrcopy_mode is the node-side loader for the AMI-driver path;
  # it must not run alongside the GPU Operator's own gdrcopy sidecar (which needs the
  # operator to manage the driver). If both are active they race to load gdrdrv. This is a
  # cross-variable validation (Terraform >= 1.9) so it hard-fails at plan time — unlike a
  # `check` block, which only warns and would let a two-loader config apply.
  validation {
    condition     = var.gdrcopy_mode == "off" || !(var.gpu_operator_install_driver && var.gpu_operator_enable_gdrcopy)
    error_message = "gdrcopy_mode is not \"off\" (node-side gdrdrv load) while the GPU Operator is also set to load gdrdrv (gpu_operator_install_driver && gpu_operator_enable_gdrcopy). Pick one loader: set gdrcopy_mode = \"off\", or disable the operator's gdrcopy."
  }
}

variable "gdrcopy_loader_image" {
  description = <<-EOT
    Image for the gdrdrv-loader DaemonSet (gdrcopy_mode = "daemonset"). Only used to run
    the host's dnf/modprobe via chroot, so any minimal AL2023-compatible base works. Pin
    to a digest (…@sha256:…) in production per the same rationale as other images here;
    the default mutable tag is for convenience.
  EOT
  type        = string
  default     = "public.ecr.aws/amazonlinux/amazonlinux:2023"
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

variable "trainer_enabled" {
  description = <<-EOT
    Install Kubeflow Trainer v2 (TrainJob, trainer.kubeflow.org/v1alpha1) — the successor to
    the legacy Training Operator v1 (PyTorchJob). One Helm release installs the control plane,
    the standard ClusterTrainingRuntimes, and its JobSet dependency. Disable for inference-only
    clusters that never run a TrainJob.
  EOT
  type        = bool
  default     = true
}

variable "trainer_chart_version" {
  description = <<-EOT
    Kubeflow Trainer Helm chart version, pulled from oci://ghcr.io/kubeflow/charts/kubeflow-trainer.
    Pinned to a stable release (not a chart bundled in-repo — the whole point of the v2 move is
    that the vendored-manifest machinery of the old operator disappears). The CRD apiVersion is
    v1alpha1 regardless of this chart version.
  EOT
  type        = string
  default     = "2.2.1"
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

variable "cpu_node_volume_throughput" {
  description = <<-EOT
    gp3 throughput (MiB/s) for CPU node root volumes. CPU nodes have no NVMe instance store, so
    the root gp3 IS the image filesystem; gp3's 125 MiB/s baseline throttles multi-GB image
    pulls (download + extract both write here). 500 is a cheap, effective default (gp3 bills
    throughput separately and CPU nodes are short-lived). Range 125-1000.
  EOT
  type        = number
  default     = 500
}

variable "cpu_node_volume_iops" {
  description = "gp3 IOPS for CPU node root volumes. Raised from the 3000 baseline to match the higher throughput during image extract. Range 3000-16000."
  type        = number
  default     = 6000
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

###############################################################################
# Observability (observability.tf) — kube-prometheus-stack. On by default.
###############################################################################

variable "enable_observability" {
  description = "Deploy the kube-prometheus-stack (Prometheus + Grafana + DCGM GPU metrics) on a dedicated monitoring NodePool. On by default."
  type        = bool
  default     = true
}

variable "kube_prometheus_stack_version" {
  description = "Helm chart version for kube-prometheus-stack (prometheus-community). Pin it: the chart carries CRDs, so unattended version drift is unsafe. See README for the CRD upgrade step."
  type        = string
  default     = "75.6.0" # attachMetadata(node) supported; bump per README CRD step
}

variable "prometheus_retention" {
  description = "Prometheus TSDB retention by time."
  type        = string
  default     = "15d"
}

variable "prometheus_retention_size" {
  description = "Prometheus TSDB size cap (oldest blocks dropped on overflow). Second bound so a series spike cannot fill the disk and crash-loop Prometheus. Leave null to derive ~90% of prometheus_storage_size automatically."
  type        = string
  default     = null
}

variable "prometheus_storage_size" {
  description = "Prometheus PVC size (gp3)."
  type        = string
  default     = "50Gi"
}

variable "grafana_storage_size" {
  description = "Grafana PVC size (gp3)."
  type        = string
  default     = "10Gi"
}

variable "observability_storage_class" {
  description = "StorageClass name the monitoring PVCs reference. Default gp3, created by this module (see observability_storage_class_create) because a cluster's default SC may still be the in-tree gp2."
  type        = string
  default     = "gp3"
}

variable "observability_storage_class_create" {
  description = "Create the gp3 EBS-CSI StorageClass named observability_storage_class. Set false to reference a pre-existing StorageClass of that name instead (avoids clobbering an existing immutable SC)."
  type        = bool
  default     = true
}

variable "observability_instance_categories" {
  description = "Instance categories for the dedicated monitoring NodePool (Karpenter karpenter.k8s.aws/instance-category). Defaults to general-purpose/memory families; monitoring is memory-bound."
  type        = list(string)
  default     = ["c", "m"]
}

variable "tenant_node_label_key" {
  description = "Node label key stamped by karpenter-tenant-pools (Experiment01) on tenant nodes; observability relabels it to a `tenant` label on GPU metrics. Keep in sync with the operator's configuration."
  type        = string
  default     = "tenantpools.dev/tenant"
}
