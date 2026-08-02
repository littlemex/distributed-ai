# capacity-block.tf
# Resolve Capacity Block (CB) reservation metadata from the reservation IDs in
# var.accelerator_pools, so tfvars only carries cb_reservation_id (cr-...) and never a
# hand-copied cb_end_date or a zone that can drift out of sync with the reservation.
#
# The AWS provider has no `aws_ec2_capacity_reservation` data source (only the purchase-side
# aws_ec2_capacity_block_offering), so we shell out via an external data source to
# `aws ec2 describe-capacity-reservations` — the same aws-CLI dependency the local-exec
# provisioners in this module already rely on. No new provider beyond hashicorp/external.
#
# Derived per reserved pool:
#   - end_date          : feeds the pre-expiry SNS alert (eventbridge-cb-alarm.tf).
#   - availability_zone : the AZ a reserved pool pins to. az.tf's local.pool_zone READS this
#                         (a reserved pool with zone="" inherits it), so the pool can never
#                         disagree with its CB. If a pool ALSO sets an explicit zone, the check
#                         block below warns when that explicit zone contradicts the CB's AZ.
#   - state             : gated to "active" so a plan/apply against a still-"scheduled" CB
#                         surfaces a loud WARNING at plan time (via the check block below),
#                         instead of Karpenter silently failing to launch nodes. NOTE: a
#                         check-block assertion only WARNS -- it does NOT block the apply
#                         (see the check block's own comment); it is a visibility aid, not a gate.

locals {
  # Reserved pools that carry at least one reservation id. Keyed by pool name. This reads the
  # NORMALIZED pool_effective view (locals.tf, ADR0001) rather than the raw legacy fields, so a
  # pool declared in EITHER form is recognized: legacy (capacity_type="reserved" +
  # cb_reservation_id) OR new (capacity_types=["reserved"] + capacity_reservations={ids=[...]}).
  # Keying off the raw p.capacity_type == "reserved" here would silently drop new-form reserved
  # pools from the CB describe below — and therefore from CB end-date alerts (eventbridge-cb-alarm.tf)
  # and zone auto-resolution — with no plan/apply error. Requires reservation_ids to be non-empty
  # (tag-only reservations expose no id to describe; a variables.tf validation guarantees a reserved
  # pool has ids or tags, and zone/end-date auto-resolution only applies to id-based reservations).
  cb_reserved_pools = {
    for k, p in var.accelerator_pools : k => p
    if local.pool_effective[k].has_reserved && length(local.pool_effective[k].reservation_ids) > 0
  }

  # Distinct reservation ids across all reserved pools (new-form pools may carry several),
  # comma-joined for a single describe call.
  cb_reservation_ids_csv = join(",", distinct(flatten([
    for k, p in local.cb_reserved_pools : local.pool_effective[k].reservation_ids
  ])))
}

# One describe call for all reserved reservation ids. Config depends only on var values, so
# the read resolves at plan/refresh time (values are known during plan) — do NOT add
# depends_on, which would defer the read to apply and make end_date/zone unknown at plan.
data "external" "capacity_reservations" {
  count   = length(local.cb_reserved_pools) > 0 ? 1 : 0
  program = ["bash", "${path.module}/scripts/describe_capacity_reservations.sh"]
  query = {
    ids    = local.cb_reservation_ids_csv
    region = var.region
    # Pass the same profile the AWS provider uses so the describe call resolves the SAME
    # account/credentials. Without it the script would fall back to the ambient credential
    # chain and, in a multi-profile shell, could describe a reservation in the wrong account.
    # Normalize null → "" so the external data source receives a valid string.
    # The script treats "" as "use ambient credentials" (no --profile flag).
    profile = var.aws_profile != null ? var.aws_profile : ""
  }
}

locals {
  # Flat "<id>.<field>" result map (empty when there are no reserved pools).
  cb_meta_flat = length(local.cb_reserved_pools) > 0 ? data.external.capacity_reservations[0].result : {}

  # Representative reservation id per reserved pool: the first normalized id (pool_effective
  # merges legacy cb_reservation_id and new capacity_reservations.ids). end_date/zone/state are
  # read for this id. A pool bundling several reservations is rare; the first reservation's AZ
  # is the representative zone (all ids in one pool should share an AZ anyway). Using the raw
  # legacy p.cb_reservation_id here would look up "" for a new-form pool and silently drop it.
  pool_cb_rep_id = {
    for k, p in local.cb_reserved_pools : k => local.pool_effective[k].reservation_ids[0]
  }

  # Per-pool derived values. end_date: an explicit tfvars cb_end_date still wins (emergency
  # override); otherwise use the reservation's EndDate. zone/state are read straight from the
  # reservation for validation below.
  pool_cb_end_date = {
    for k, p in local.cb_reserved_pools : k => (
      p.cb_end_date != "" ? p.cb_end_date : lookup(local.cb_meta_flat, "${local.pool_cb_rep_id[k]}.end_date", "")
    )
  }
  pool_cb_zone = {
    for k, p in local.cb_reserved_pools : k =>
    lookup(local.cb_meta_flat, "${local.pool_cb_rep_id[k]}.availability_zone", "")
  }
  pool_cb_state = {
    for k, p in local.cb_reserved_pools : k =>
    lookup(local.cb_meta_flat, "${local.pool_cb_rep_id[k]}.state", "")
  }
}

# Surface a loud WARNING on a still-scheduled/expired CB and on a CR/zone mismatch. A check
# block WARNS on every plan/apply but does NOT block the apply (that is intentional here:
# gating a NodePool's for_each on state would silently DESTROY the NodePool when a CB later
# flips to "expired", which is worse than a warning). So this is a visibility aid, not a
# hard gate -- treat the warning as the signal to act, do not expect it to stop an apply.
check "capacity_block_ready" {
  assert {
    condition = alltrue([
      for k, s in local.pool_cb_state : s == "active"
    ])
    error_message = "A Capacity Block for a reserved accelerator pool is not active: ${jsonencode(local.pool_cb_state)}. If a CB shows state=\"\" it was not found (deleted/expired and purged) — remove it from tfvars. Otherwise wait for the CB to flip to 'active' before applying — Karpenter cannot launch nodes against a scheduled/expired reservation."
  }
  assert {
    # Only relevant when a reserved pool sets an EXPLICIT zone (p.zone != ""). With the default
    # (zone == ""), local.pool_zone READS the CB's AZ, so there is nothing to mismatch. A
    # non-empty p.zone that contradicts the CB means the operator is trying to override the
    # derived AZ with a wrong one — warn (a live plan continues, but Karpenter would never
    # launch a node because the zone requirement and capacityReservationSelectorTerms conflict).
    condition = alltrue([
      for k, p in local.cb_reserved_pools :
      p.zone == "" || local.pool_cb_zone[k] == "" || local.pool_cb_zone[k] == p.zone
    ])
    error_message = "A reserved pool sets an explicit zone that does not match its Capacity Block's AZ. Pools: ${jsonencode({ for k, p in local.cb_reserved_pools : k => { pool_zone = p.zone, cb_zone = local.pool_cb_zone[k] } })}. Clear the pool's zone (leave it \"\") to inherit the CB's AZ automatically, or fix it to match."
  }
}
