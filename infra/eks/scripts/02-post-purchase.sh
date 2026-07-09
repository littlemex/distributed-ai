#!/usr/bin/env bash
# 02-post-purchase.sh
# Write the purchased Capacity Block's CR-ID and end-date into
# infra/eks/terraform.tfvars.local so that Terraform picks them up.
#
# Usage:
#   ./02-post-purchase.sh --cr-id cr-0123456789abcdef0 --end-date 2026-07-11T12:00:00Z
#
# The CR-ID and end-date are printed by 01-purchase-cb.sh.
# terraform.tfvars.local is .gitignored; it holds environment-specific overrides.

set -euo pipefail

CR_ID=""
END_DATE=""

# Resolve script dir so paths are correct regardless of cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TFVARS_LOCAL="$INFRA_DIR/terraform.tfvars.local"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cr-id)    CR_ID="$2";    shift 2 ;;
    --end-date) END_DATE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$CR_ID" ]] || [[ -z "$END_DATE" ]]; then
  echo "Error: --cr-id and --end-date are both required." >&2
  echo "  Example: $0 --cr-id cr-0123456789abcdef0 --end-date 2026-07-11T12:00:00Z" >&2
  exit 1
fi

# Validate CR-ID format
if [[ ! "$CR_ID" =~ ^cr-[0-9a-f]+$ ]]; then
  echo "Warning: CR-ID '$CR_ID' does not match expected pattern cr-<hex>." >&2
fi

# ── Write / update terraform.tfvars.local ─────────────────────────────────────
# If the file already exists, remove stale cb_reservation_id / cb_end_date lines before appending.
if [[ -f "$TFVARS_LOCAL" ]]; then
  TMP=$(mktemp)
  grep -v '^cb_reservation_id\|^cb_end_date' "$TFVARS_LOCAL" > "$TMP" || true
  mv "$TMP" "$TFVARS_LOCAL"
fi

cat >> "$TFVARS_LOCAL" <<EOF

# Written by 02-post-purchase.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
cb_reservation_id = "$CR_ID"
cb_end_date        = "$END_DATE"
EOF

echo "Written to: $TFVARS_LOCAL"
echo ""
echo "  cb_reservation_id = \"$CR_ID\""
echo "  cb_end_date        = \"$END_DATE\""
echo ""
echo "Next steps:"
echo "  1. Review the values above."
echo "  2. cd $INFRA_DIR && terraform plan -var-file=terraform.tfvars.local"
echo "  3. terraform apply -var-file=terraform.tfvars.local"
