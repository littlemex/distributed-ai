#!/usr/bin/env bash
# Tests for the installer's plan guard, against synthetic plans. No cluster, no AWS, no Terraform.
#
# This exists because the guard was wrong three times in a row, each time in a way that only appeared
# in someone else's environment: it refused the first install of a data layer, then refused resuming
# one that had failed half way, and in between it filed a data layer's own IAM roles as unrelated
# cluster drift. Every one of those is a plan shape, so every one of them is a test.
#
# The rule the table below locks down: a delete of the record of record is refused and cannot be
# overridden; anything else in a state that belongs to this platform is applied; anything else in the
# cluster's state stops the run unless it is explicitly allowed.

_pg_installer() { printf '%s' "$SCRIPT_DIR/../../scripts/install-profiling.sh"; }

# The guard's body is extracted from the installer rather than duplicated here, so this cannot drift
# into testing a copy that no longer matches what runs.
_pg_extract() {
  local out="$1"
  python3 - "$(_pg_installer)" "$out" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index("import json, os, re, sys")
end = src.index("\nPY\n", start)
open(sys.argv[2], "w").write(src[start:end])
PY
}

# addr -> actions, rendered as a terraform show -json plan
_pg_plan() {
  python3 - "$@" <<'PY'
import json, sys
changes = []
for pair in sys.argv[1:]:
    addr, actions = pair.split("=", 1)
    changes.append({"address": addr, "change": {"actions": actions.split(",")}})
print(json.dumps({"resource_changes": changes}))
PY
}

# Runs the guard and reports its verdict as "ok" or "refused:<bucket>".
_pg_verdict() {
  local label="$1" allow="$2" only="$3" records="${PG_ALLOW_RECORD_UPDATES:-0}"; shift 3
  local dir out rc
  dir="$(mktemp -d)"
  _pg_extract "$dir/guard.py"
  # The real address lists, read out of the installer, for the same reason as the body.
  sed -n '/^profiling_addresses()/,/^ADDR/p' "$(_pg_installer)" | sed '1d;$d' | tail -n +2 >"$dir/owned.txt"
  sed -n '/^protected_addresses()/,/^ADDR/p' "$(_pg_installer)" | sed '1d;$d' | tail -n +2 >"$dir/protected.txt"
  _pg_plan "$@" >"$dir/plan.json"
  out=$(LABEL="$label" ALLOW_UNRELATED="$allow" PROFILING_ONLY="$only" \
    ALLOW_RECORD_UPDATES="$records" python3 "$dir/guard.py" "$dir/plan.json" "$dir/owned.txt" "$dir/protected.txt" 2>&1)
  rc=$?
  rm -rf "$dir"
  if [ $rc -eq 0 ]; then printf 'ok'; else printf 'refused'; fi
  printf ' %s' "$(printf '%s' "$out" | tr '\n' '|')"
}

_pg_expect() {
  local want="$1" desc="$2"; shift 2
  local got
  got="$(_pg_verdict "$@")"
  case "$got" in
    "$want"*) return 0 ;;
    *) printf 'FAIL %s\n  want: %s...\n  got:  %s\n' "$desc" "$want" "$got" >&2; return 1 ;;
  esac
}

test_plan_guard_table() {
  command -v python3 >/dev/null || return 2
  local fails=0

  # A data layer created for the first time: every resource in it is a create, including the record of
  # record. This is the case that was refused, blocking any first install.
  _pg_expect ok "data-layer first install" data-layer 0 0 \
    'aws_s3_bucket.traces["us-east-2"]=create' 'aws_kms_key.data=create' \
    'aws_sagemaker_mlflow_tracking_server.this[0]=create' 'aws_iam_role.producer=create' || fails=$((fails + 1))

  # The same data layer, resumed after the apply failed part way: only what is missing is created.
  # This was refused too, which left a half-built data layer with no way forward.
  _pg_expect ok "data-layer resume after a partial apply" data-layer 0 0 \
    'aws_sagemaker_mlflow_tracking_server.this[0]=create' || fails=$((fails + 1))

  # A data layer's own IAM roles are not cluster drift. Classifying them with the cluster's list made
  # the run stop on "unrelated changes" that were the data layer itself.
  _pg_expect ok "data-layer IAM is not unrelated drift" data-layer 0 0 \
    'aws_iam_role_policy.janitor=update' 'terraform_data.lifecycle_guard=create' || fails=$((fails + 1))

  # Deleting the record of record is refused, in either state, with no override.
  _pg_expect refused "data-layer delete of the record of record" data-layer 0 0 \
    'aws_s3_bucket.traces["us-east-2"]=delete' || fails=$((fails + 1))
  _pg_expect refused "delete is refused even with ALLOW_UNRELATED" data-layer 1 0 \
    'aws_sagemaker_mlflow_tracking_server.this[0]=delete' || fails=$((fails + 1))
  _pg_expect refused "a replacement is a delete" data-layer 0 0 \
    'aws_kms_key.data=delete,create' || fails=$((fails + 1))

  # On the cluster side the platform is a guest, so anything else is drift and stops the run.
  _pg_expect refused "cluster drift stops the run" cluster 0 0 \
    'helm_release.karpenter=update' || fails=$((fails + 1))
  _pg_expect ok "cluster drift with ALLOW_UNRELATED" cluster 1 0 \
    'helm_release.karpenter=update' || fails=$((fails + 1))
  # PROFILING_ONLY changes how the plan is made, so an unrelated change that survives into it is
  # still applied when the saved plan is applied. Only ALLOW_UNRELATED may wave that through.
  _pg_expect refused "PROFILING_ONLY does not wave unrelated changes through" cluster 0 1 \
    'helm_release.karpenter=update' || fails=$((fails + 1))
  _pg_expect ok "the platform's own cluster resources are applied" cluster 0 0 \
    'aws_ecr_repository.profiling=create' 'kubectl_manifest.mcp_namespace=create' || fails=$((fails + 1))

  # An update to the record of record can lose data without deleting anything: a shorter lifecycle, a
  # narrowed policy, a rewritten Cloud Control desired_state. It needs to be asked for by name.
  _pg_expect refused "an update to the record of record needs an explicit ack" data-layer 0 0 \
    'aws_s3_bucket_lifecycle_configuration.traces["us-east-2"]=update' || fails=$((fails + 1))
  _pg_expect refused "ALLOW_UNRELATED does not cover a record update" data-layer 1 1 \
    'aws_kms_key.data=update' || fails=$((fails + 1))
  PG_ALLOW_RECORD_UPDATES=1 _pg_expect ok "ALLOW_RECORD_UPDATES covers it" data-layer 0 0 \
    'aws_kms_key.data=update' || fails=$((fails + 1))
  PG_ALLOW_RECORD_UPDATES=1 _pg_expect refused "and never covers a delete" data-layer 1 1 \
    'aws_kms_key.data=delete' || fails=$((fails + 1))

  # And a delete on the cluster side is still refused, override or not.
  _pg_expect refused "cluster delete of the record of record" cluster 1 1 \
    'aws_cloudcontrolapi_resource.s3files_fs[0]=delete' || fails=$((fails + 1))

  [ "$fails" -eq 0 ] || { printf '%d guard case(s) failed\n' "$fails" >&2; return 1; }
}
