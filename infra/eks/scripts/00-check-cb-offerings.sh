#!/usr/bin/env bash
# 00-check-cb-offerings.sh
# List available Capacity Block offerings, with the up-front price for each.
# Read-only — no charges incurred.
#
# Usage:
#   ./00-check-cb-offerings.sh \
#     [--region us-east-2] \
#     [--instance-types p4d.24xlarge,p5en.48xlarge] \
#     [--instance-count 2] \
#     [--duration-hours 24] \
#     [--days-ahead 7]
#
# Requirements:
#   aws CLI, profile with EC2 describe permissions (set AWS_PROFILE; defaults to "default")
#
# Instance types are NOT hardcoded to one accelerator family: pass whichever family the
# workshop needs (p4d, p5, p5en, p6-b300, trn1, trn2, ...). With --instance-types omitted the
# script asks EC2 which types in this region support Capacity Blocks and probes those, so a
# newly launched family shows up without editing this file.
#
# UpfrontFee is the TOTAL charge for the block (all instances, whole duration) — not per hour
# and not per instance. Divide by (instance-count x duration-hours) for an effective per
# instance-hour rate to compare against On-Demand.

set -euo pipefail

# AWS_REGION first: every chapter in the workshop exports AWS_REGION, and reading only
# AWS_DEFAULT_REGION meant a reader who set AWS_REGION=us-west-2 silently searched us-east-2
# and got "could not describe reservation" — or worse, a same-shaped id in another region.
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
# Empty, not "default": passing --profile default breaks the common case of credentials
# coming from the environment or an instance role with no [default] profile on disk.
# 02-post-purchase.sh already did it this way; the two scripts now agree.
PROFILE="${AWS_PROFILE:-}"
INSTANCE_TYPES=""
INSTANCE_COUNT=2
DURATION_HOURS=24
DAYS_AHEAD=7

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)         REGION="$2";         shift 2 ;;
    --profile)        PROFILE="$2";        shift 2 ;;
    --instance-types) INSTANCE_TYPES="$2"; shift 2 ;;
    --instance-count) INSTANCE_COUNT="$2"; shift 2 ;;
    --duration-hours) DURATION_HOURS="$2"; shift 2 ;;
    --days-ahead)     DAYS_AHEAD="$2";     shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

AWS_CMD="aws --region $REGION"
[[ -n "$PROFILE" ]] && AWS_CMD="$AWS_CMD --profile $PROFILE"

# The offering search window. The API rejects an end date beyond what it currently sells
# (roughly 8 days out for short blocks), so --days-ahead is clamped on error below.
START_RANGE=$(python3 -c "import datetime;print((datetime.datetime.utcnow()+datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
END_RANGE=$(python3 -c "import datetime,sys;print((datetime.datetime.utcnow()+datetime.timedelta(days=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$DAYS_AHEAD")

# Discover Capacity-Block-capable accelerator types from EC2 when the caller did not name any.
if [[ -z "$INSTANCE_TYPES" ]]; then
  echo "Discovering Capacity-Block-capable instance types in ${REGION} ..."
  INSTANCE_TYPES=$($AWS_CMD ec2 describe-instance-types \
    --filters "Name=supported-usage-class,Values=capacity-block" \
    --query 'InstanceTypes[].InstanceType' --output text 2>/dev/null | tr '\t' '\n' | sort -u | paste -sd, -)
  if [[ -z "$INSTANCE_TYPES" ]]; then
    echo "  No Capacity-Block-capable instance types reported for ${REGION}." >&2
    echo "  Pass --instance-types <type[,type...]> explicitly." >&2
    exit 1
  fi
fi

echo "=== Capacity Block Offerings ==="
echo "Region        : $REGION"
echo "Profile       : ${PROFILE:-(none set; using the ambient credentials)}"
echo "Instance count: $INSTANCE_COUNT"
echo "Duration      : ${DURATION_HOURS}h"
echo "Window        : $START_RANGE .. $END_RANGE"
echo ""

IFS=',' read -r -a TYPE_ARRAY <<< "$INSTANCE_TYPES"

for ITYPE in "${TYPE_ARRAY[@]}"; do
  [[ -z "$ITYPE" ]] && continue
  echo "--- $ITYPE ---"
  RESULT=$($AWS_CMD ec2 describe-capacity-block-offerings \
    --instance-type "$ITYPE" \
    --instance-count "$INSTANCE_COUNT" \
    --capacity-duration-hours "$DURATION_HOURS" \
    --start-date-range "$START_RANGE" \
    --end-date-range "$END_RANGE" \
    --output json 2>&1) || {
      # Surface the API's own message (bad end date, unsupported type, ...) instead of a
      # bare "no offerings", so the caller can tell "sold out" from "wrong request".
      echo "  API error: $(echo "$RESULT" | tail -1)"
      echo ""
      continue
    }

  echo "$RESULT" | python3 -c '
import json, sys
data = json.load(sys.stdin).get("CapacityBlockOfferings", [])
if not data:
    print("  (no offerings available — sold out for this window/size)")
    sys.exit(0)
print("  %-22s %-14s %5s %5s %12s %14s" % ("OfferingId", "AZ", "Cnt", "Hrs", "UpfrontUSD", "USD/inst-hour"))
for o in data:
    cnt = o.get("InstanceCount", 0)
    hrs = o.get("CapacityBlockDurationHours", 0)
    fee = float(o.get("UpfrontFee", 0) or 0)
    per = fee / (cnt * hrs) if cnt and hrs else 0
    print("  %-22s %-14s %5s %5s %12.2f %14.2f" % (
        o.get("CapacityBlockOfferingId", "")[:22],
        o.get("AvailabilityZone", ""), cnt, hrs, fee, per))
    print("    start %s  end %s" % (o.get("StartDate"), o.get("EndDate")))
'
  echo ""
done

echo "UpfrontFee is the TOTAL charge for the whole block (all instances x full duration)."
echo "Compare USD/inst-hour against the On-Demand rate for the same instance type."
