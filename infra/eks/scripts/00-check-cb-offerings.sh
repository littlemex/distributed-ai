#!/usr/bin/env bash
# 00-check-cb-offerings.sh
# List available Capacity Block offerings for p5en and p5 instance families.
# Read-only — no charges incurred.
#
# Usage:
#   ./00-check-cb-offerings.sh [--region us-east-2] [--duration-hours 24]
#
# Requirements:
#   aws CLI, profile with EC2 describe permissions (set AWS_PROFILE; defaults to "default")

set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-east-2}"
PROFILE="${AWS_PROFILE:-default}"
DURATION_HOURS=24

# Parse optional arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)        REGION="$2";        shift 2 ;;
    --profile)       PROFILE="$2";       shift 2 ;;
    --duration-hours) DURATION_HOURS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

AWS_CMD="aws --region $REGION --profile $PROFILE"

echo "=== Capacity Block Offerings ==="
echo "Region  : $REGION"
echo "Profile : $PROFILE"
echo "Duration: ${DURATION_HOURS}h"
echo ""

for FAMILY in p5en p5; do
  echo "--- Instance family: ${FAMILY}.48xlarge ---"
  $AWS_CMD ec2 describe-capacity-block-offerings \
    --instance-type "${FAMILY}.48xlarge" \
    --instance-count 2 \
    --capacity-duration-hours "$DURATION_HOURS" \
    --query 'CapacityBlockOfferings[*].{
      OfferingId:CapacityBlockOfferingId,
      AZ:AvailabilityZone,
      Start:StartDate,
      End:EndDate,
      Count:InstanceCount,
      USD:UpfrontFee
    }' \
    --output table 2>/dev/null \
    || echo "  (no offerings found for ${FAMILY}.48xlarge in ${REGION})"
  echo ""
done

echo "Tip: pass --instance-count N and --capacity-duration-hours H to narrow results."
echo "     Pricing is per-reservation; UpfrontFee is the total charge shown above."
