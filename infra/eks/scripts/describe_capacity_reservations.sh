#!/usr/bin/env bash
# Terraform external data source helper: resolve Capacity Block reservation metadata
# (end_date, availability_zone, state) from reservation IDs, so tfvars only needs the
# cb_reservation_id and never a hand-copied cb_end_date / zone.
#
# Protocol (hashicorp/external): reads a JSON object on stdin and must print a flat JSON
# object of string->string on stdout. Terraform passes the whole `query` map as stdin.
#
# Input  (stdin):  {"ids": "cr-aaa,cr-bbb", "region": "us-east-2", "profile": "myprofile"}
#   profile may be "" (use the ambient credential chain).
# Output (stdout): a flat map keyed by "<id>.<field>", e.g.
#   {"cr-aaa.end_date":"2026-07-21T11:30:00+00:00","cr-aaa.availability_zone":"us-east-2a",
#    "cr-aaa.state":"active", ...}
# The flat "<id>.<field>" shape is required because external data sources cannot return
# nested objects; the Terraform side unflattens it in locals.
#
# Requires: aws CLI + jq (already relied on by the local-exec provisioners in this module).
set -euo pipefail

# profile key may be absent on older callers; default to "".
eval "$(jq -r '@sh "IDS=\(.ids) REGION=\(.region) PROFILE=\(.profile // "")"')"

# No reserved pools -> return an empty object (valid external result).
if [[ -z "${IDS}" ]]; then
  echo '{}'
  exit 0
fi

# Split "cr-a,cr-b" into args. describe-capacity-reservations takes multiple ids in one call.
IFS=',' read -r -a ID_ARR <<< "${IDS}"

# Pass --profile through only when set, so the describe uses the same account as the provider.
PROFILE_ARGS=()
[[ -n "${PROFILE}" ]] && PROFILE_ARGS=(--profile "${PROFILE}")

# Capture stderr so we can distinguish "reservation gone" from "cannot reach AWS".
# A typo'd or already-deleted reservation id (InvalidCapacityReservationId*) is a benign
# "not found": emit an empty map so the Terraform check block reports the pool as degraded
# (state resolves to "" -> not "active" -> warns) instead of failing the plan opaquely.
# Any OTHER failure (expired creds, no network, throttling) must fail LOUD -- otherwise an
# empty result would make the plan compute a DELETE of the live scheduler/SNS resources.
if ! RAW=$(aws ec2 describe-capacity-reservations \
      --region "${REGION}" "${PROFILE_ARGS[@]}" \
      --capacity-reservation-ids "${ID_ARR[@]}" \
      --output json 2>/tmp/cb_describe_err.$$); then
  ERR=$(cat /tmp/cb_describe_err.$$ 2>/dev/null); rm -f /tmp/cb_describe_err.$$
  if grep -q "InvalidCapacityReservationId" <<< "${ERR}"; then
    echo '{}'
    exit 0
  fi
  echo "describe_capacity_reservations: AWS call failed (not a not-found): ${ERR}" >&2
  exit 1
fi
rm -f /tmp/cb_describe_err.$$

printf '%s' "${RAW}" | jq -c '
    .CapacityReservations
    | map({
        ("\(.CapacityReservationId).end_date"):          (.EndDate // ""),
        ("\(.CapacityReservationId).availability_zone"): (.AvailabilityZone // ""),
        ("\(.CapacityReservationId).state"):             (.State // "")
      })
    | add // {}
  '
