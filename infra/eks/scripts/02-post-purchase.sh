#!/usr/bin/env bash
# 02-post-purchase.sh
# Print the Terraform snippet to add a purchased Capacity Block to a reserved accelerator
# pool. Capacity Block id and expiry are per-pool fields on accelerator_pools (there is no
# top-level cb_reservation_id anymore), so this script cannot know which pool key you want —
# it emits a ready-to-paste block for you to add to terraform.tfvars.
#
# Usage:
#   ./02-post-purchase.sh --cr-id cr-0123456789abcdef0 --end-date 2026-07-11T12:00:00Z \
#       [--instance-type p5en.48xlarge] [--pool gpu-p5en] [--zone us-east-2a]
#
# The CR-ID and end-date are printed by 01-purchase-cb.sh.
#
# A reserved pool's zone is DERIVED from the reservation (az.tf reads the CB's AZ), so the
# emitted block does NOT set `zone` by default — a CB moving AZ then needs only its new
# cb_reservation_id. Pass --zone only to pin an explicit override into the block.

set -euo pipefail

CR_ID=""
END_DATE=""
INSTANCE_TYPE="p5en.48xlarge"
ZONE=""
POOL="gpu-cb"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cr-id)         CR_ID="$2";         shift 2 ;;
    --end-date)      END_DATE="$2";      shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --zone)          ZONE="$2";          shift 2 ;;
    --pool)          POOL="$2";          shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$CR_ID" ]] || [[ -z "$END_DATE" ]]; then
  echo "Error: --cr-id and --end-date are both required." >&2
  echo "  Example: $0 --cr-id cr-0123456789abcdef0 --end-date 2026-07-11T12:00:00Z" >&2
  exit 1
fi

if [[ ! "$CR_ID" =~ ^cr-[0-9a-f]+$ ]]; then
  echo "Warning: CR-ID '$CR_ID' does not match expected pattern cr-<hex>." >&2
fi

# Pick device_plugin from the instance family (trn/inf → neuron, else nvidia).
DEVICE_PLUGIN="nvidia"
case "$INSTANCE_TYPE" in
  trn*|inf*) DEVICE_PLUGIN="neuron" ;;
esac

cat <<EOF

Add this reserved pool to accelerator_pools in terraform.tfvars, then apply:

  ${POOL} = {
    instance_types    = ["${INSTANCE_TYPE}"]
    device_plugin     = "${DEVICE_PLUGIN}"
    capacity_type     = "reserved"
    cb_reservation_id = "${CR_ID}"           # zone is derived from this reservation
    cb_end_date       = "${END_DATE}"   # optional: schedules a pre-expiry SNS alert
    volume_size       = "500Gi"
EOF
if [[ -n "$ZONE" ]]; then
  cat <<EOF
    zone              = "${ZONE}"           # explicit override of the derived CB AZ
EOF
fi
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
