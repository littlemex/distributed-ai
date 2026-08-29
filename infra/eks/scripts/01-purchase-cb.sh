#!/usr/bin/env bash
# 01-purchase-cb.sh
# Purchase a Capacity Block reservation and pass the CR-ID to 02-post-purchase.sh.
#
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# WARNING: THIS SCRIPT INCURS REAL AWS CHARGES.
# A single p5en.48xlarge 24-hour Capacity Block costs approximately $1,318 USD.
# REQUIRES EXPLICIT APPROVAL from your budget owner before running.
# This script will show a price summary and prompt for confirmation before
# making any purchase.
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#
# Usage:
#   ./01-purchase-cb.sh \
#     --offering-id <CapacityBlockOfferingId> \
#     --instance-type p5en.48xlarge \
#     --instance-count 2
#
# The offering ID is obtained from 00-check-cb-offerings.sh.
# On confirmation, purchases the CB and writes the CR-ID to the screen.
# Run 02-post-purchase.sh with the printed CR-ID to update terraform.tfvars.local.

set -euo pipefail

# AWS_REGION first: every chapter in the workshop exports AWS_REGION, and reading only
# AWS_DEFAULT_REGION meant a reader who set AWS_REGION=us-west-2 silently searched us-east-2
# and got "could not describe reservation" — or worse, a same-shaped id in another region.
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
# Empty, not "default": passing --profile default breaks credentials that come from the
# environment or an instance role with no [default] profile on disk. Matches the other two.
PROFILE="${AWS_PROFILE:-}"
OFFERING_ID=""
INSTANCE_TYPE="p5en.48xlarge"
INSTANCE_COUNT=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)         REGION="$2";         shift 2 ;;
    --profile)        PROFILE="$2";        shift 2 ;;
    --offering-id)    OFFERING_ID="$2";    shift 2 ;;
    --instance-type)  INSTANCE_TYPE="$2";  shift 2 ;;
    --instance-count) INSTANCE_COUNT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$OFFERING_ID" ]]; then
  echo "Error: --offering-id is required. Run 00-check-cb-offerings.sh first." >&2
  exit 1
fi

AWS_CMD="aws --region $REGION"
[[ -n "$PROFILE" ]] && AWS_CMD="$AWS_CMD --profile $PROFILE"

# ── Dry-run: fetch offering details and show pricing ──────────────────────────
echo ""
echo "=== Capacity Block Purchase Preview ==="
echo ""

OFFERING=$($AWS_CMD ec2 describe-capacity-block-offerings \
  --instance-type "$INSTANCE_TYPE" \
  --instance-count "$INSTANCE_COUNT" \
  --capacity-duration-hours 24 \
  --query "CapacityBlockOfferings[?CapacityBlockOfferingId=='${OFFERING_ID}'] | [0]" \
  --output json 2>/dev/null || echo "null")

if [[ "$OFFERING" == "null" ]] || [[ -z "$OFFERING" ]]; then
  # Fallback: describe with broader query (duration may differ)
  echo "Note: could not locate offering details for dry-run — proceeding with manual confirmation."
  echo ""
  echo "  Offering ID   : $OFFERING_ID"
  echo "  Instance type : $INSTANCE_TYPE"
  echo "  Instance count: $INSTANCE_COUNT"
  echo "  Region        : $REGION"
else
  AZ=$(echo "$OFFERING"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('AvailabilityZone','n/a'))")
  START=$(echo "$OFFERING" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('StartDate','n/a'))")
  END=$(echo "$OFFERING"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('EndDate','n/a'))")
  FEE=$(echo "$OFFERING"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('UpfrontFee','n/a'))")

  echo "  Offering ID   : $OFFERING_ID"
  echo "  Instance type : $INSTANCE_TYPE  x${INSTANCE_COUNT}"
  echo "  Availability Zone: $AZ"
  echo "  Start         : $START"
  echo "  End           : $END"
  echo "  Upfront fee   : \$${FEE} USD  ← YOU WILL BE BILLED THIS AMOUNT"
fi

echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "  THIS INCURS REAL AWS CHARGES / REQUIRES EXPLICIT BUDGET APPROVAL"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo ""

# ── Confirmation prompt ───────────────────────────────────────────────────────
read -rp "Proceed with purchase? [y/N] " CONFIRM
if [[ "${CONFIRM,,}" != "y" ]]; then
  echo "Aborted. No charges incurred."
  exit 0
fi

# ── Purchase ──────────────────────────────────────────────────────────────────
echo ""
echo "Purchasing Capacity Block..."

RESULT=$($AWS_CMD ec2 purchase-capacity-block \
  --capacity-block-offering-id "$OFFERING_ID" \
  --instance-platform "Linux/UNIX" \
  --output json)

CR_ID=$(echo "$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['CapacityReservation']['CapacityReservationId'])")
END_DATE=$(echo "$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['CapacityReservation']['EndDate'])")

echo ""
echo "=== Purchase Successful ==="
echo "  CapacityReservationId : $CR_ID"
echo "  EndDate               : $END_DATE"
echo ""
echo "Next step — emit the terraform.tfvars pool block (type/zone/end date are"
echo "resolved from the CR-ID automatically):"
echo "  ./02-post-purchase.sh --cr-id $CR_ID"
