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
#    "cr-aaa.state":"active","cr-aaa.found":"true",
#    "cr-bbb.found":"false","cr-bbb.end_date":"","cr-bbb.availability_zone":"","cr-bbb.state":""}
# A reservation that is deleted or not found degrades gracefully (found=false, empty fields)
# rather than failing the entire call — this prevents a stale CR ID from taking down the
# metadata resolution for all other live reservations.
#
# Requires: aws CLI + jq (already relied on by the local-exec provisioners in this module).
set -euo pipefail

eval "$(jq -r '@sh "IDS=\(.ids) REGION=\(.region) PROFILE=\(.profile // "")"')"

if [[ -z "${IDS}" ]]; then
  echo '{}'
  exit 0
fi

IFS=',' read -r -a ID_ARR <<< "${IDS}"

PROFILE_ARGS=()
[[ -n "${PROFILE}" ]] && PROFILE_ARGS=(--profile "${PROFILE}")

# List ALL capacity reservations in the region (including expired/cancelled), then filter
# client-side by the requested IDs. This avoids the "one bad ID kills the whole batch"
# problem of --capacity-reservation-ids, where a deleted reservation causes the API to
# reject the entire request with InvalidCapacityReservationId.
if ! RAW=$(aws ec2 describe-capacity-reservations \
      --region "${REGION}" "${PROFILE_ARGS[@]}" \
      --filters "Name=instance-match-criteria,Values=targeted" \
      --output json 2>/tmp/cb_describe_err.$$); then
  ERR=$(cat /tmp/cb_describe_err.$$ 2>/dev/null); rm -f /tmp/cb_describe_err.$$
  echo "describe_capacity_reservations: AWS call failed: ${ERR}" >&2
  exit 1
fi
rm -f /tmp/cb_describe_err.$$

# Build a lookup map from the API response, then emit results for each requested ID.
# IDs not found in the response get found=false with empty fields.
REQUESTED=$(printf '%s\n' "${ID_ARR[@]}" | jq -R . | jq -s .)

printf '%s' "${RAW}" | jq -c --argjson requested "${REQUESTED}" '
  .CapacityReservations
  | map({key: .CapacityReservationId, value: .})
  | from_entries as $lookup
  | $requested
  | map(. as $id |
      if $lookup[$id] then
        {
          ("\($id).end_date"):          ($lookup[$id].EndDate // ""),
          ("\($id).availability_zone"): ($lookup[$id].AvailabilityZone // ""),
          ("\($id).state"):             ($lookup[$id].State // ""),
          ("\($id).found"):             "true"
        }
      else
        {
          ("\($id).end_date"):          "",
          ("\($id).availability_zone"): "",
          ("\($id).state"):             "",
          ("\($id).found"):             "false"
        }
      end
    )
  | add // {}
'
