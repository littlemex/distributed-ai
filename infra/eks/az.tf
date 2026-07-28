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
      condition     = var.fsx_subnet_index < local.num_azs && var.openzfs_subnet_index < local.num_azs
      error_message = "fsx_subnet_index / openzfs_subnet_index must be < the AZ count (${local.num_azs}); they index into the per-AZ private subnets."
    }
  }
}
