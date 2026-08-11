# az.tf
# Single source of truth for "what AZs does this cluster span, and which AZ does each pool
# pin to". The design goal: a normal deployment sets only `region` (+ instance types in the
# pools) and nothing about zones — everything below is derived. This is what makes the
# cluster resilient to a Capacity Block's AZ changing between reservations: the VPC spans the
# WHOLE region, so a CB landing in ANY AZ always has a matching subnet, and a reserved pool's
# zone is read FROM the reservation (never hand-copied), so a CB move needs only its new
# cb_reservation_id.
#
# Resolution order for each knob (explicit var wins, else derived):
#   AZ list           var.azs               → else every standard AZ in the region.
#   private CIDRs     var.private_subnet_cidrs → else one /18-class block per AZ (low half of VPC).
#   public CIDRs      var.public_subnet_cidrs  → else one /24 per AZ (top half of VPC).
#   pool zone         pool.zone             → else reserved: CB's AZ; on-demand/spot: azs[0].

# All standard (opt-in-not-required — i.e. not Local Zone / Wavelength) AZs in the region.
# Resolves at plan time. NOTE: this includes constrained AZs such as us-east-1e that do not
# support the EKS control plane or newer instance types; in those regions set var.azs
# explicitly to the AZs you want (see the variable's docs). us-west-2 / us-east-2 (this
# project's regions) have no such AZ, so the default spans them all safely.
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  # Resolved AZ list. Explicit var.azs wins (escape hatch for pinning a specific set/order or
  # excluding a constrained AZ); otherwise span every standard region AZ, sorted so the index
  # order (which fixes subnet order, and thus var.fsx_subnet_index / var.openzfs_subnet_index)
  # is deterministic.
  azs     = var.azs != null ? var.azs : sort(data.aws_availability_zones.available.names)
  num_azs = length(local.azs)

  # ── Auto-derived subnet CIDRs ───────────────────────────────────────────────
  # Carve from var.vpc_cidr so the subnet list ALWAYS has exactly one entry per AZ (it cannot
  # desync from local.azs the way a hand-maintained list can). Private subnets take the low
  # half of the VPC split evenly across the AZs; public subnets take /24s from the top half so
  # they never eat into the large private ranges (the "public small, private huge" principle).
  vpc_low_half  = cidrsubnet(var.vpc_cidr, 1, 0) # e.g. 10.0.0.0/17   for a /16 VPC
  vpc_high_half = cidrsubnet(var.vpc_cidr, 1, 1) # e.g. 10.0.128.0/17 for a /16 VPC

  # Extra prefix bits needed to split the low half into num_azs equal private subnets
  # (smallest k with 2^k >= num_azs). Static map avoids floating-point rounding in log(); no
  # standard region exceeds 6 AZs, and the fallback covers up to 16 just in case.
  priv_newbits_by_count = { 1 = 0, 2 = 1, 3 = 2, 4 = 2, 5 = 3, 6 = 3, 7 = 3, 8 = 3 }
  priv_newbits          = lookup(local.priv_newbits_by_count, local.num_azs, 4)

  # Public subnets are a fixed /24: newbits = 24 - (prefix length of the high half). For a /16
  # VPC the high half is /17, so newbits = 7 → /24. Derived from the actual prefix so it stays
  # a /24 even if var.vpc_cidr is not a /16.
  vpc_high_half_prefix = tonumber(split("/", local.vpc_high_half)[1])
  public_newbits       = 24 - local.vpc_high_half_prefix

  derived_private_subnets = [for i in range(local.num_azs) : cidrsubnet(local.vpc_low_half, local.priv_newbits, i)]
  derived_public_subnets  = [for i in range(local.num_azs) : cidrsubnet(local.vpc_high_half, local.public_newbits, i)]

  private_subnets = var.private_subnet_cidrs != null ? var.private_subnet_cidrs : local.derived_private_subnets
  public_subnets  = var.public_subnet_cidrs != null ? var.public_subnet_cidrs : local.derived_public_subnets

  # ── Per-pool resolved zone ──────────────────────────────────────────────────
  # An explicit pool.zone wins; otherwise a reserved pool inherits its Capacity Block's AZ
  # (local.pool_cb_zone, resolved from the reservation in capacity-block.tf) and an
  # on-demand/spot pool defaults to the first AZ. Karpenter pins the NodePool to this AZ
  # (karpenter-resources.tf) and it must be one of local.azs (enforced below).
  pool_zone = {
    for k, p in var.accelerator_pools : k => (
      p.zone != "" ? p.zone :
      p.capacity_type == "reserved" ? lookup(local.pool_cb_zone, k, "") :
      local.azs[0]
    )
  }
}

# Cross-value invariants that a variable `validation` block cannot express (they depend on
# local.azs, which comes from a data source). A failed precondition blocks the plan.
resource "terraform_data" "az_invariants" {
  lifecycle {
    precondition {
      # Guardrail against a profile mix-up applying to the wrong account. If var.expected_account_id
      # is set and the resolved credentials point elsewhere, fail the PLAN before any resource is
      # created — this is what stops a silent full re-creation (and duplicate FSx billing) in the
      # wrong account. Skipped entirely when var.expected_account_id is null.
      condition     = var.expected_account_id == null || data.aws_caller_identity.current.account_id == var.expected_account_id
      error_message = "Credentials resolve to account ${data.aws_caller_identity.current.account_id}, but expected_account_id is ${coalesce(var.expected_account_id, "null")}. You are almost certainly applying with the wrong AWS profile. Fix the profile (or var.expected_account_id) before applying — proceeding would re-create the cluster in the wrong account."
    }
    precondition {
      condition     = local.num_azs >= 2
      error_message = "The cluster resolved to fewer than 2 AZs (${local.num_azs}). The EKS control plane requires subnets in at least two AZs. Set var.azs explicitly or use a region with >= 2 standard AZs."
    }
    precondition {
      condition     = length(local.private_subnets) == local.num_azs && length(local.public_subnets) == local.num_azs
      error_message = "Subnet CIDR count must equal the AZ count (${local.num_azs}). When you set var.private_subnet_cidrs / var.public_subnet_cidrs explicitly, give exactly one CIDR per resolved AZ; leave them null to auto-derive."
    }
    precondition {
      # Every pool's RESOLVED zone must be a real AZ in the VPC, or Karpenter pins the NodePool
      # to a zone with no subnet and nodes never launch (visible only in Karpenter events).
      condition = alltrue([
        for k, z in local.pool_zone : contains(local.azs, z)
      ])
      error_message = "An accelerator pool resolved to a zone that is not one of the cluster AZs. Resolved zones: ${jsonencode(local.pool_zone)}; cluster AZs: ${jsonencode(local.azs)}. A reserved pool whose CB is in an AZ outside var.azs, or an explicit pool.zone typo, causes this — clear var.azs to span the whole region, or fix the zone."
    }
    precondition {
      # NEW zones list (ADR D4): every AZ named in a pool's `zones` must be a real cluster AZ,
      # except the "*" wildcard (= all cluster AZs). Checked here (not in a variable validation)
      # because it needs local.azs from a data source. Pools that leave zones unset are exempt
      # (they derive azs[0] via local.pool_effective[*].zones = []); this keeps existing tfvars valid.
      condition = alltrue([
        for k, n in local.pool_effective :
        alltrue([for z in n.zones : z == "*" || contains(local.azs, z)])
      ])
      error_message = "An accelerator pool's zones list names an AZ that is not one of the cluster AZs. Per-pool zones: ${jsonencode({ for k, n in local.pool_effective : k => n.zones })}; cluster AZs: ${jsonencode(local.azs)}. Use \"*\" for all AZs, or one of the cluster AZs; leave zones unset to derive azs[0]."
    }
    precondition {
      condition     = var.fsx_subnet_index < local.num_azs && var.openzfs_subnet_index < local.num_azs
      error_message = "fsx_subnet_index / openzfs_subnet_index must be < the AZ count (${local.num_azs}); they index into the per-AZ private subnets."
    }
    precondition {
      # FSx-EFA minimums (AWS API): EFA requires USER_PROVISIONED metadata >= 6000 IOPS and
      # >= 4800 GiB capacity. fsx_metadata_iops's own validation already forbids < 1500 etc.;
      # this adds the EFA-specific >= 6000 / >= 4800 GiB floor, and only when EFA is enabled.
      # (Kept here, not as a variable validation, so both fsx vars can be cross-checked.)
      condition     = !var.fsx_efa_enabled || (var.fsx_metadata_iops >= 6000 && var.fsx_storage_capacity_gib >= 4800)
      error_message = "fsx_efa_enabled = true requires fsx_metadata_iops >= 6000 and fsx_storage_capacity_gib >= 4800 (EFA-enabled FSx for Lustre minimums). Got iops=${var.fsx_metadata_iops}, capacity=${var.fsx_storage_capacity_gib}."
    }
    precondition {
      # DERIVED-EFA × multi-AZ guard (ADR D5). The variable validation catches only an EXPLICIT
      # efa_interface_count > 0 + multi-AZ; it cannot see a pool that leaves efa_interface_count = -1
      # (derive) and sets zones = ["*"] on an EFA instance type, because the resolved topology
      # (local.pool_efa, which reads the EC2 API via data.aws_ec2_instance_type) is a local, not available to a
      # variable validation. Check it HERE against the fully-resolved values: pool_efa[k].count is
      # the effective EFA card count and pool_zone_requirement_values[k] is the final AZ list Karpenter pins to.
      # An EFA pool (count > 0) spread over more than one AZ would silently break multi-node NCCL
      # (EFA/RDMA is not routable across subnets — ranks hang or fall back to slow TCP), with no
      # plan/apply error. Non-EFA pools (count <= 0) and single-AZ EFA pools pass.
      condition = alltrue([
        for k, e in local.pool_efa :
        e.count <= 0 || length(local.pool_zone_requirement_values[k]) <= 1
      ])
      error_message = "An EFA-enabled accelerator pool resolved to more than one AZ. Effective EFA cards / resolved zones per pool: ${jsonencode({ for k, e in local.pool_efa : k => { efa = e.count, zones = local.pool_zone_requirement_values[k] } })}. EFA/RDMA cannot cross subnets, so an EFA pool must pin to ONE AZ — set zones to a single AZ, or set efa_interface_count = 0 to disable EFA on that pool."
    }
  }
}
