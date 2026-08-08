#!/usr/bin/env bash
# 02-post-purchase.sh
# Print the Terraform snippet to add a purchased Capacity Block to a reserved accelerator
# pool. Everything about the reservation — instance type, availability zone, end date — is
# resolved from the CR-ID via `aws ec2 describe-capacity-reservations`, so the CR-ID is the
# only thing you must supply. The emitted block is a per-pool entry in accelerator_pools,
# which lives in accelerator-pools.auto.tfvars (NOT terraform.tfvars — see Basic04). This
# script cannot know which pool key you want — pass --pool (defaults to gpu-cb).
#
# Usage:
#   ./02-post-purchase.sh --cr-id cr-0123456789abcdef0 [--pool gpu-cb] \
#       [--region us-east-2] [--profile <name>]
#
# The CR-ID is printed by 01-purchase-cb.sh.
#
# A reserved pool's zone is DERIVED from the reservation at plan time (az.tf reads the CB's
# AZ), so the emitted block does NOT set `zone` — a CB moving AZ then needs only its new
# cb_reservation_id.

set -euo pipefail

CR_ID=""
POOL="gpu-cb"
REGION="${AWS_DEFAULT_REGION:-us-east-2}"
PROFILE="${AWS_PROFILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cr-id)   CR_ID="$2";   shift 2 ;;
    --pool)    POOL="$2";    shift 2 ;;
    --region)  REGION="$2";  shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$CR_ID" ]]; then
  echo "Error: --cr-id is required." >&2
  echo "  Example: $0 --cr-id cr-0123456789abcdef0" >&2
  exit 1
fi

if [[ ! "$CR_ID" =~ ^cr-[0-9a-f]+$ ]]; then
  echo "Warning: CR-ID '$CR_ID' does not match expected pattern cr-<hex>." >&2
fi

# ── Resolve everything from the CR-ID ─────────────────────────────────────────
AWS_ARGS=(--region "$REGION")
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")

RESV=$(aws "${AWS_ARGS[@]}" ec2 describe-capacity-reservations \
  --capacity-reservation-ids "$CR_ID" \
  --query 'CapacityReservations[0].{type:InstanceType,az:AvailabilityZone,end:EndDate,rtype:ReservationType}' \
  --output json 2>/dev/null || echo "null")

if [[ "$RESV" == "null" ]] || [[ -z "$RESV" ]]; then
  echo "Error: could not describe reservation '$CR_ID' in $REGION." >&2
  echo "  Check the CR-ID, --region, and your credentials (--profile)." >&2
  exit 1
fi

INSTANCE_TYPE=$(echo "$RESV" | python3 -c "import sys,json; print(json.load(sys.stdin)['type'])")
# EndDate comes back as RFC3339 with a numeric offset (e.g. "...+00:00"), but the
# accelerator_pools validation requires a UTC "Z" suffix (a non-Z offset is
# misread as UTC by the EventBridge schedule). Normalize any offset to a "Z"
# instant so the emitted cb_end_date passes validation as-is.
END_DATE=$(echo "$RESV" | python3 -c "
import sys, json
from datetime import timezone
d = json.load(sys.stdin).get('end') or ''
if d:
    from datetime import datetime
    # Python 3.11+ parses trailing 'Z'; older needs +00:00. Handle both.
    d = datetime.fromisoformat(d.replace('Z', '+00:00')).astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
print(d)
")
AZ=$(echo "$RESV"            | python3 -c "import sys,json; print(json.load(sys.stdin).get('az') or '')")
RTYPE=$(echo "$RESV"         | python3 -c "import sys,json; print(json.load(sys.stdin).get('rtype') or '')")

if [[ "$RTYPE" != "capacity-block" ]]; then
  echo "Warning: reservation '$CR_ID' has ReservationType '$RTYPE' (expected capacity-block)." >&2
fi

# Pick device_plugin from the instance family (trn/inf → neuron, else nvidia).
DEVICE_PLUGIN="nvidia"
case "$INSTANCE_TYPE" in
  trn*|inf*) DEVICE_PLUGIN="neuron" ;;
esac

echo "Resolved from ${CR_ID}: ${INSTANCE_TYPE} in ${AZ}, ends ${END_DATE:-n/a}." >&2

cat <<EOF

Add this reserved pool to accelerator_pools in accelerator-pools.auto.tfvars, then apply:

  ${POOL} = {
    instance_types    = ["${INSTANCE_TYPE}"]
    device_plugin     = "${DEVICE_PLUGIN}"
    capacity_type     = "reserved"
    cb_reservation_id = "${CR_ID}"           # zone/end date are derived from this reservation
    cb_end_date       = "${END_DATE}"   # optional: schedules a pre-expiry SNS alert
    volume_size       = "500Gi"
EOF
if [[ "$DEVICE_PLUGIN" == "neuron" ]]; then
  cat <<EOF
    ami_ssm_parameter = "/aws/service/eks/optimized-ami/1.35/amazon-linux-2023/x86_64/neuron/recommended/image_id"
EOF
fi
cat <<EOF
  }

Then:
  terraform apply
  kubectl get nodes -l karpenter.sh/capacity-type=reserved
EOF
