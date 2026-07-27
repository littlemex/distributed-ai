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
#   - availability_zone : validated against the pool's hand-set zone (catch a CR/zone mismatch
#                         before Karpenter pins a NodePool to the wrong AZ and can't launch).
#   - state             : gated to "active" so a plan/apply against a still-"scheduled" CB
#                         surfaces a loud WARNING at plan time (via the check block below),
#                         instead of Karpenter silently failing to launch nodes. NOTE: a
#                         check-block assertion only WARNS -- it does NOT block the apply
#                         (see the check block's own comment); it is a visibility aid, not a gate.

locals {
  # Reserved pools that carry a reservation id. Keyed by pool name.
  cb_reserved_pools = {
    for k, p in var.accelerator_pools : k => p
    if p.capacity_type == "reserved" && p.cb_reservation_id != ""
  }

  # Distinct reservation ids, comma-joined for a single describe call.
  cb_reservation_ids_csv = join(",", distinct([
    for k, p in local.cb_reserved_pools : p.cb_reservation_id
  ]))
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

  # Per-pool derived values. end_date: an explicit tfvars cb_end_date still wins (emergency
  # override); otherwise use the reservation's EndDate. zone/state are read straight from the
  # reservation for validation below.
  pool_cb_end_date = {
    for k, p in local.cb_reserved_pools : k => (
      p.cb_end_date != "" ? p.cb_end_date : lookup(local.cb_meta_flat, "${p.cb_reservation_id}.end_date", "")
    )
  }
  pool_cb_zone = {
    for k, p in local.cb_reserved_pools : k =>
    lookup(local.cb_meta_flat, "${p.cb_reservation_id}.availability_zone", "")
  }
  pool_cb_state = {
    for k, p in local.cb_reserved_pools : k =>
    lookup(local.cb_meta_flat, "${p.cb_reservation_id}.state", "")
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
    error_message = "A Capacity Block for a reserved accelerator pool is not active yet: ${jsonencode(local.pool_cb_state)}. Wait for the CB to flip to 'active' before applying — Karpenter cannot launch nodes against a scheduled/expired reservation."
  }
  assert {
    condition = alltrue([
      for k, p in local.cb_reserved_pools :
      local.pool_cb_zone[k] == "" || local.pool_cb_zone[k] == p.zone
    ])
    error_message = "A reserved pool's zone does not match its Capacity Block's AZ. Pools: ${jsonencode({ for k, p in local.cb_reserved_pools : k => { pool_zone = p.zone, cb_zone = local.pool_cb_zone[k] } })}. Fix the pool's zone (or the reservation id) so Karpenter pins the NodePool to the CB's AZ."
  }
}
