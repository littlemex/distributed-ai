#!/usr/bin/env bash
# distai-attach-data-layer.sh — record that a cluster uses a data layer, and which one is its default.
#
#   infra/scripts/distai-attach-data-layer.sh -c my-cluster -l mcp [--default]
#   infra/scripts/distai-attach-data-layer.sh -c my-cluster --list
#   infra/scripts/distai-attach-data-layer.sh -c my-cluster -l mcp --detach
#
# A data layer (infra/data-layer) is a second Terraform state holding the trace bucket, the MLflow
# tracking server and the S3 Files filesystem. Which layer a cluster records into is a relationship
# between two states, so it lives in neither: this script writes it to the registry, and everything
# downstream reads it from there.
#
# Why not a default value: DATA_LAYER_NAME used to fall back to "mcp", and that default silently
# pointed a cluster at a data layer in another region. An unattached cluster is now an error with a
# name, not a guess.
#
# A cluster may have several layers attached (one per tenant, per retention policy, or per region) and
# exactly one default. That is why a layer is an entry under data-layers/ rather than a single value:
# the multiplicity exists from the first write, so growing into it later needs no migration.
#
# Options:
#   -c NAME       cluster (required)
#   -l LAYER      data layer name (required except with --list)
#   -r REGION     region of the registry. Default: AWS_REGION, else the CLI's configured region
#   --default     also make this the cluster's default data layer
#   --detach      remove the attachment. Refuses while it is still the default
#   --list        show what is attached, and which one is the default
#   --owner TEAM  recorded on the attachment, for inventory
#   --retention P recorded on the attachment, for whoever cleans up later
set -euo pipefail

usage() { sed -n '2,${/^[^#]/q;p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
say() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

cluster="" layer="" region="" owner="" retention="" make_default=false detach=false list=false
while [ $# -gt 0 ]; do
  case "$1" in
    -c) cluster="$2"; shift 2 ;;
    -l) layer="$2"; shift 2 ;;
    -r) region="$2"; shift 2 ;;
    --owner) owner="$2"; shift 2 ;;
    --retention) retention="$2"; shift 2 ;;
    --default) make_default=true; shift ;;
    --detach) detach=true; shift ;;
    --list) list=true; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "${cluster}" ] || { printf 'error: -c <cluster> is required\n' >&2; usage 1; }
[ -n "${region}" ] || region="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
[ -n "${region}" ] || die "no region. Pass -r, set AWS_REGION, or configure one."

prefix="/distai/v1/clusters/${cluster}"
aws ssm get-parameter --name "${prefix}/state/bucket" --region "${region}" >/dev/null 2>&1 ||
  die "cluster '${cluster}' is not in the registry in ${region}. Run infra/scripts/distai-up.sh first."

current_default() {
  aws ssm get-parameter --name "${prefix}/defaults/data-layer" --region "${region}" \
    --query Parameter.Value --output text 2>/dev/null || true
}
attached_layers() {
  aws ssm get-parameters-by-path --path "${prefix}/data-layers" --recursive --region "${region}" \
    --query 'Parameters[].Name' --output text 2>/dev/null | tr '\t' '\n' |
    sed "s|${prefix}/data-layers/||" | sed 's|/.*||' | sort -u | grep -v '^$' || true
}

if [ "${list}" = true ]; then
  say "data layers attached to ${cluster} (${region})"
  default="$(current_default)"
  found=false
  while IFS= read -r l; do
    [ -n "${l}" ] || continue
    found=true
    if [ "${l}" = "${default}" ]; then printf '    %s (default)\n' "${l}"; else printf '    %s\n' "${l}"; fi
  done <<<"$(attached_layers)"
  [ "${found}" = true ] || printf '    none\n'
  exit 0
fi

[ -n "${layer}" ] || { printf 'error: -l <layer> is required\n' >&2; usage 1; }
printf '%s' "${layer}" | grep -Eq '^[a-z0-9][a-z0-9-]{1,62}$' ||
  die "data layer name must match ^[a-z0-9][a-z0-9-]{1,62}$ (it becomes a registry path and a state key)"

if [ "${detach}" = true ]; then
  [ "$(current_default)" != "${layer}" ] ||
    die "'${layer}' is the default for ${cluster}. Point the default elsewhere first, so nothing resolves to a layer that is gone."
  say "detaching ${layer} from ${cluster}"
  # The attachment is removed; the data layer itself and its recorded runs are untouched. Deleting a
  # data layer is a separate, deliberate act against its own Terraform state.
  aws ssm delete-parameter --name "${prefix}/data-layers/${layer}/manifest" --region "${region}" >/dev/null
  printf '    the data layer itself was not touched\n'
  exit 0
fi

say "attaching ${layer} to ${cluster}"
manifest="$(LAYER="${layer}" CLUSTER="${cluster}" OWNER="${owner}" RETENTION="${retention}" \
  RELEASE="$(git -C "$(dirname "${BASH_SOURCE[0]}")" describe --tags --always 2>/dev/null || echo unknown)" \
  python3 -c '
import json, os, datetime
print(json.dumps({
    "schema": 1,
    "data_layer": os.environ["LAYER"],
    "owner_cluster": os.environ["CLUSTER"],
    "attached_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "attached_release": os.environ["RELEASE"],
    "owner_team": os.environ["OWNER"] or None,
    "retention": os.environ["RETENTION"] or None,
}, separators=(",", ":")))')"
# Overwritten deliberately: attaching a layer that is already attached is a re-statement of the same
# relationship, and the manifest carries when it was last stated.
aws ssm put-parameter --name "${prefix}/data-layers/${layer}/manifest" --type String --overwrite \
  --value "${manifest}" --region "${region}" >/dev/null
printf '    %s\n' "${manifest}"

if [ "${make_default}" = true ]; then
  say "making ${layer} the default for ${cluster}"
  aws ssm put-parameter --name "${prefix}/defaults/data-layer" --type String --overwrite \
    --value "${layer}" --region "${region}" >/dev/null
elif [ -z "$(current_default)" ]; then
  # Being the first attachment is not the same as being chosen, but a cluster with exactly one layer
  # and no default would make every later command ask for one. The first is adopted, and said out loud.
  say "no default was set; adopting ${layer} as the default because it is the first"
  aws ssm put-parameter --name "${prefix}/defaults/data-layer" --type String --overwrite \
    --value "${layer}" --region "${region}" >/dev/null
fi

printf '\n    resolve it from any chapter with:\n\n      export CLUSTER_NAME=%s\n      source "$(git rev-parse --show-toplevel)/infra/scripts/distai-env.sh"\n\n' "${cluster}"
