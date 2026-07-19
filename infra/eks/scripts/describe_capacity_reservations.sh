#!/usr/bin/env bash
# Terraform external data source helper: resolve Capacity Block reservation metadata
# (end_date, availability_zone, state) from reservation IDs, so tfvars only needs the
# cb_reservation_id and never a hand-copied cb_end_date / zone.
#
# Protocol (hashicorp/external): reads a JSON object on stdin and must print a flat JSON
# object of string->string on stdout. Terraform passes the whole `query` map as stdin.
#
# Input  (stdin):  {"ids": "cr-aaa,cr-bbb", "region": "us-east-2"}
# Output (stdout): a flat map keyed by "<id>.<field>", e.g.
#   {"cr-aaa.end_date":"2026-07-21T11:30:00+00:00","cr-aaa.availability_zone":"us-east-2a",
#    "cr-aaa.state":"active", ...}
# The flat "<id>.<field>" shape is required because external data sources cannot return
# nested objects; the Terraform side unflattens it in locals.
#
# Requires: aws CLI + jq (already relied on by the local-exec provisioners in this module).
set -euo pipefail

eval "$(jq -r '@sh "IDS=\(.ids) REGION=\(.region)"')"

# No reserved pools -> return an empty object (valid external result).
if [[ -z "${IDS}" ]]; then
  echo '{}'
  exit 0
fi

# Split "cr-a,cr-b" into args. describe-capacity-reservations takes multiple ids in one call.
IFS=',' read -r -a ID_ARR <<< "${IDS}"

aws ec2 describe-capacity-reservations \
  --region "${REGION}" \
  --capacity-reservation-ids "${ID_ARR[@]}" \
  --output json \
| jq -c '
    .CapacityReservations
    | map({
        ("\(.CapacityReservationId).end_date"):          (.EndDate // ""),
        ("\(.CapacityReservationId).availability_zone"): (.AvailabilityZone // ""),
        ("\(.CapacityReservationId).state"):             (.State // "")
      })
    | add // {}
  '
