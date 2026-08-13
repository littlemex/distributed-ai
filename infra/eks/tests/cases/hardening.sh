#!/usr/bin/env bash
# Hardening live test cases. Files under cases/ group functions by area; each test's layer and suite
# are declared in registry.sh (the single source).

expected_reaper_pools_json() {
  tf_console 'jsonencode(sort(keys(local.accelerator_stuck_node_reaper_pools)))'
}

expected_reaper_dry_run() {
  tf_console 'local.accelerator_stuck_node_reaper_dry_run'
}

test_reaper_cronjob_presence() {
  local expected name cronjobs namespace config_pools
  expected="$(expected_reaper_pools_json)"
  name="$(reaper_name)"
  cronjobs="$(kubectl get cronjob -A -o json | jq -r --arg name "$name" '[.items[] | select(.metadata.name == $name)]')"
  if [ "$expected" = "[]" ]; then
    [ "$(printf '%s' "$cronjobs" | jq 'length')" -eq 0 ] || return 1
    return 0
  fi
  [ "$(printf '%s' "$cronjobs" | jq 'length')" -eq 1 ] || return 1
  namespace="$(printf '%s' "$cronjobs" | jq -r '.[0].metadata.namespace')"
  config_pools="$(kubectl get configmap "$name" -n "$namespace" -o jsonpath='{.data.config\.json}' | jq -c '.pools | keys | sort')"
  [ "$config_pools" = "$expected" ]
}

test_reaper_dryrun_flag() {
  local expected name namespace actual
  expected="$(expected_reaper_dry_run)"
  name="$(reaper_name)"
  namespace="$(resolve_reaper_namespace)"
  [ -n "$namespace" ] || return 2
  actual="$(kubectl get configmap "$name" -n "$namespace" -o jsonpath='{.data.config\.json}' | jq -r '.dry_run')"
  [ "$actual" = "$expected" ]
}

test_reaper_dryrun_job() {
  local expected name namespace job before after logs
  expected="$(expected_reaper_dry_run)"
  [ "$expected" = true ] || return 2
  name="$(reaper_name)"
  namespace="$(resolve_reaper_namespace)"
  [ -n "$namespace" ] || return 2
  # Job names must fit the 63-char DNS label limit; cap the prefix at 52 chars to leave room for
  # the "-<10-digit epoch>" uniqueness suffix appended below. NAMESPACE is a global (SC2153).
  # shellcheck disable=SC2153
  job="${name}-dryrun-$(safe_name "$NAMESPACE")"
  job="${job:0:52}-$(date +%s)"
  before="$(kubectl get nodeclaims -o name 2>/dev/null | sort || true)"
  kubectl create job "$job" -n "$namespace" --from="cronjob/$name"
  # Delete the Job on both exit paths of run_test's `( set -e; ... )` subshell: EXIT covers an
  # errexit failure (which exits, not returns); TERM covers the watchdog's process-group SIGTERM on
  # timeout (bash does not run the EXIT trap for an untrapped fatal signal). `exit 143` keeps
  # run_test's "143 + deadline reached -> 124 (timeout)" mapping intact. Both are independent of the
  # parent harness teardown trap.
  trap 'kubectl delete job "$job" -n "$namespace" --wait=false >/dev/null 2>&1 || true' EXIT
  trap 'kubectl delete job "$job" -n "$namespace" --wait=false >/dev/null 2>&1 || true; exit 143' TERM
  wait_for_job "$namespace" "$job" 300
  logs="$(kubectl logs job/"$job" -n "$namespace" 2>/dev/null || true)"
  printf '%s\n' "$logs" | grep -Eq 'DRY-RUN|no NodeClaims found'
  after="$(kubectl get nodeclaims -o name 2>/dev/null | sort || true)"
  [ "$before" = "$after" ]
}
