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

# addr=actions[@@before_json@@after_json] rendered as a terraform show -json plan. The before/after form
# is needed to test the changes that are ignored for being nothing but a re-fetched credential. The
# separator is @@ rather than a colon, which JSON already uses.
_pg_plan() {
  python3 - "$@" <<'PY'
import json, sys
changes = []
for spec in sys.argv[1:]:
    parts = spec.split("@@", 2)
    addr, actions = parts[0].split("=", 1)
    change = {"actions": actions.split(",")}
    if len(parts) == 3:
        change["before"] = json.loads(parts[1])
        change["after"] = json.loads(parts[2])
    changes.append({"address": addr, "change": change})
print(json.dumps({"resource_changes": changes}))
PY
}

# Runs the guard and reports its verdict as "ok" or "refused:<bucket>".
_pg_verdict() {
  local label="$1" allow="$2" only="$3" records="${PG_ALLOW_RECORD_UPDATES:-0}"; shift 3
  local dir out rc
  dir="$(mktemp -d)"
  _pg_extract "$dir/guard.py"
  # The real address lists, obtained the way the installer obtains them: the owned list is derived from
  # the Terraform sources by a function in the installer, so it is sourced and called rather than
  # scraped, and the protected list is still a literal.
  eks_dir="$SCRIPT_DIR/.." bash -c "source <(sed -n '/^profiling_source_files()/,/^}/p;/^profiling_addresses()/,/^}/p' '$(_pg_installer)'); profiling_addresses" >"$dir/owned.txt"
  sed -n '/^protected_addresses()/,/^ADDR/p' "$(_pg_installer)" | sed '1,2d;$d' >"$dir/protected.txt"
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
  # Both shapes of MLflow, because whichever one a data layer created is the one holding its run
  # metadata, and a backend switch arrives as exactly this plan.
  _pg_expect refused "deleting the MLflow app is refused" data-layer 1 0 \
    'aws_sagemaker_mlflow_app.this[0]=delete' || fails=$((fails + 1))
  _pg_expect refused "swapping an app for a tracking server is refused" data-layer 1 1 \
    'aws_sagemaker_mlflow_app.this[0]=delete' 'aws_sagemaker_mlflow_tracking_server.this[0]=create' ||
    fails=$((fails + 1))
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

  # The helm provider re-fetches an ECR auth token on every plan, so a cluster whose charts come from
  # ECR carries two of these updates forever. Reporting them would make ALLOW_UNRELATED a habit.
  _pg_expect ok "a change that is only a re-fetched credential is not drift" cluster 0 0 \
    'helm_release.karpenter=update@@{"repository_password":"old","version":"1.0"}@@{"repository_password":"new","version":"1.0"}' \
    || fails=$((fails + 1))
  # But a real change to the same resource is still drift.
  _pg_expect refused "a real helm change is still drift" cluster 0 0 \
    'helm_release.karpenter=update@@{"repository_password":"old","version":"1.0"}@@{"repository_password":"new","version":"1.1"}' \
    || fails=$((fails + 1))

  # And a delete on the cluster side is still refused, override or not.
  _pg_expect refused "cluster delete of the record of record" cluster 1 1 \
    'aws_cloudcontrolapi_resource.s3files_fs[0]=delete' || fails=$((fails + 1))

  [ "$fails" -eq 0 ] || { printf '%d guard case(s) failed\n' "$fails" >&2; return 1; }
}

# The owned list is derived from the files that define the platform's cluster-side resources. This
# asserts the derivation actually covers them — the omission it replaces (three IAM resources the S3
# Files mount needs) stopped an install with "unrelated drift" that was the platform itself.
test_plan_guard_owned_list_is_complete() {
  local installer missing=""
  installer="$(_pg_installer)"
  local derived
  derived="$(eks_dir="$SCRIPT_DIR/.." bash -c "source <(sed -n '/^profiling_source_files()/,/^}/p;/^profiling_addresses()/,/^}/p' '$installer'); profiling_addresses")"
  local addr
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    printf '%s\n' "$derived" | grep -qxF "$addr" || missing="${missing} ${addr}"
  done <<EOF
$(grep -hoE '^resource "[^"]+" "[^"]+"' "$SCRIPT_DIR/../s3files-mount.tf" "$SCRIPT_DIR/../iam-mcp.tf" \
  "$SCRIPT_DIR/../ecr-profiling.tf" | sed 's/^resource "//; s/" "/./; s/"$//')
EOF
  [ -z "$missing" ] || { printf 'not in the derived owned list:%s\n' "$missing" >&2; return 1; }
}

# A new file carrying the platform's own toggles would put resources outside the derivation above, and
# they would come back as someone else's drift. This is the tripwire for that.
test_plan_guard_no_platform_resources_elsewhere() {
  local stray
  stray="$(grep -lE 'var\.(s3files_enabled|analysis_mcp_enabled)' "$SCRIPT_DIR"/../*.tf |
    grep -vE '/(s3files-mount|iam-mcp|ecr-profiling|variables|outputs)\.tf$' || true)"
  [ -z "$stray" ] || {
    printf 'these files use the platform toggles but are not in profiling_source_files:\n%s\n' "$stray" >&2
    return 1
  }
}

# Everything in the data layer that cannot be recreated has to be in the protected list. The owned
# list is derived from the Terraform sources; this one is still a literal, because "what must never be
# deleted" is a judgement rather than a pattern — so the tripwire is that every resource the data layer
# itself marks prevent_destroy, and every configuration that decides whether those survive, is named.
test_plan_guard_protected_covers_prevent_destroy() {
  local data_dir="$SCRIPT_DIR/../../data-layer"
  [ -d "$data_dir" ] || return 2
  local protected missing=""
  protected="$(sed -n '/^protected_addresses()/,/^ADDR/p' "$(_pg_installer)" | sed '1,2d;$d')"
  # The resources carrying prevent_destroy, read out of the data layer's own files.
  local addr
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    printf '%s\n' "$protected" | grep -qxF "$addr" || missing="${missing} ${addr}"
  done <<EOF2
$(python3 - "$data_dir" <<'PY'
import glob, os, re, sys
out = []
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.tf"))):
    src = open(path).read()
    # Walk resource blocks and keep the ones whose lifecycle says prevent_destroy = true.
    for m in re.finditer(r'^resource\s+"([^"]+)"\s+"([^"]+)"\s*\{', src, re.M):
        start = m.end()
        depth, i = 1, start
        while i < len(src) and depth:
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
            i += 1
        body = src[start:i]
        if re.search(r'prevent_destroy\s*=\s*true', body):
            out.append(f"{m.group(1)}.{m.group(2)}")
print("\n".join(out))
PY
)
EOF2
  [ -z "$missing" ] || {
    printf 'these prevent_destroy resources are not in protected_addresses:%s\n' "$missing" >&2
    return 1
  }
}

# Runs the installer's own decide_mlflow_backend against a set of inputs and reports its answer, or
# "die". The function is pure, so this needs no cluster, no AWS and no Terraform; it is extracted from
# the installer rather than copied here so it cannot drift from what runs.
_pg_backend_decision() {
  local script
  script="$(mktemp)"
  {
    printf 'die() { printf "die\\n"; exit 9; }\n'
    # Sourced from a file rather than spliced into a -c string: the function's own error messages
    # contain apostrophes, and quoting them through an inline script is how a test starts testing its
    # own quoting instead of the code.
    sed -n '/^decide_mlflow_backend()/,/^}/p' "$(_pg_installer)"
    printf 'decide_mlflow_backend "$@"\n'
  } >"$script"
  grep -q '^decide_mlflow_backend()' "$script" || {
    printf 'could not extract decide_mlflow_backend\n' >&2
    rm -f "$script"
    return 2
  }
  bash "$script" "$1" "$2" "$3" "$4" 2>/dev/null || true
  rm -f "$script"
}

# Switching backends destroys the MLflow that holds the run metadata, so what a data layer already
# records to has to beat both the variable default and the environment. The rows that matter most are
# the ones where the state has lost the ARN: what is live in AWS decides then, and the mlflow_backend
# output — which only echoes a variable from the last apply — must not, or a torn-down data layer would
# resurrect the backend it used to have for someone who asked for the other one.
#
# What this does NOT cover: how the live_server / live_app arguments are discovered. That is an AWS
# lookup, and its own failure mode — reading "AWS would not answer" as "nothing is there" — is what
# test_plan_guard_aws_lookup_failure_is_not_absence below is for.
test_plan_guard_mlflow_backend_never_switches_silently() {
  local fails=0 got
  local srv="arn:aws:sagemaker:us-east-2:1:mlflow-tracking-server/profiling-mlflow"
  local app="arn:aws:sagemaker:us-east-2:1:mlflow-app/app-ABC"
  _pg_check_backend() { # want state_arn live_server live_app asked label
    got="$(_pg_backend_decision "$2" "$3" "$4" "$5")"
    [ "$got" = "$1" ] || { printf 'FAIL %s: wanted %s, got %q\n' "$6" "$1" "$got" >&2; fails=$((fails + 1)); }
  }
  _pg_check_backend app    "$app" ""      "$app" ""       "an app data layer keeps app"
  _pg_check_backend server "$srv" "srv"   ""     ""       "a server data layer keeps server"
  _pg_check_backend die    "$srv" "srv"   ""     "app"    "asking for app on a server data layer is refused"
  _pg_check_backend die    "$app" ""      "$app" "server" "asking for server on an app data layer is refused"
  # State lost the ARN (rebuilt state, or a teardown that emptied it): AWS is the authority.
  _pg_check_backend server ""     "srv"   ""     ""       "a live tracking server the state forgot decides server"
  _pg_check_backend app    ""     ""      "$app" ""       "a live app the state forgot decides app"
  _pg_check_backend die    ""     "srv"   ""     "app"    "asking for app while a tracking server is live is refused"
  _pg_check_backend die    ""     "srv"   "$app" ""       "two live MLflows and no ARN in the state is refused"
  # Nothing exists anywhere, so no records are at stake and the caller decides.
  _pg_check_backend app    ""     ""      ""     ""       "a fresh data layer defaults to app"
  _pg_check_backend server ""     ""      ""     "server" "a fresh data layer honours the request"
  unset -f _pg_check_backend
  [ "$fails" -eq 0 ] || return 1
}

# A lookup that fails is not a lookup that came back empty. Reading the first as the second is how a
# re-run creates a second, empty MLflow and points the cluster at it while the one holding the history
# sits unreferenced — nothing destroyed, nothing logged, and the plan guard never fires because there is
# no delete in it. So: only the API's own "it does not exist" may pass; everything else stops the run.
test_plan_guard_aws_lookup_failure_is_not_absence() {
  local script fails=0 got
  script="$(mktemp)"
  {
    printf 'die() { printf "die\\n"; exit 9; }\n'
    sed -n '/^aws_absent_or_die()/,/^}/p' "$(_pg_installer)"
    # The stub stands in for the CLI: it prints what $AWS_OUT says and exits with $AWS_RC.
    printf 'aws() { printf "%%s" "${AWS_OUT}"; return "${AWS_RC}"; }\n'
    printf 'aws_absent_or_die "the thing" -- sagemaker describe-something\n'
  } >"$script"
  grep -q '^aws_absent_or_die()' "$script" || { rm -f "$script"; printf 'could not extract aws_absent_or_die\n' >&2; return 2; }
  _pg_check_lookup() { # want out rc label
    got="$(env AWS_OUT="$2" AWS_RC="$3" bash "$script" 2>/dev/null || true)"
    [ "$got" = "$1" ] || { printf 'FAIL %s: wanted %q, got %q\n' "$4" "$1" "$got" >&2; fails=$((fails + 1)); }
  }
  _pg_check_lookup 'arn:aws:sagemaker:us-east-2:1:mlflow-app/app-A' \
    'arn:aws:sagemaker:us-east-2:1:mlflow-app/app-A' 0 "a successful lookup is passed through"
  _pg_check_lookup '' \
    'An error occurred (ResourceNotFound) when calling the DescribeMlflowTrackingServer operation: ...' 254 \
    "the API saying it does not exist is absence"
  _pg_check_lookup die \
    'An error occurred (AccessDeniedException) when calling the ListMlflowApps operation: ...' 254 \
    "a denied lookup stops the run"
  _pg_check_lookup die \
    'An error occurred (ThrottlingException) when calling the ListMlflowApps operation: ...' 254 \
    "a throttled lookup stops the run"
  _pg_check_lookup die "Invalid choice: 'list-mlflow-apps'" 252 \
    "a CLI too old to know the command stops the run"
  unset -f _pg_check_lookup
  rm -f "$script"
  [ "$fails" -eq 0 ] || return 1
}
