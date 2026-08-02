#!/usr/bin/env bash
# common.sh — shared helpers for run-tests.sh

set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
declare -a RESULTS=()

log_info()  { printf "[INFO] %s\n" "$*"; }
log_pass()  { printf "[OK]   %s\n" "$*"; }
log_fail()  { printf "[NG]   %s\n" "$*"; }
log_skip()  { printf "[SKIP] %s\n" "$*"; }

run_test() {
  local name="$1" timeout_sec="$2" func="$3"
  local start end elapsed rc
  start=$(date +%s)
  set +e
  # Enforce timeout_sec without a sub-shell: run the test function in the background (it keeps
  # this shell's functions/vars — aws_cmd, apply_manifest, CLUSTER_NAME, ...) and kill it if it
  # outlives the deadline. A hung kubectl/aws (e.g. unreachable API server) is aborted with
  # rc=124 instead of hanging forever. Before this, timeout_sec was accepted but never applied
  # and the rc==124 branch below was dead code.
  ( set -e; $func ) &
  local test_pid=$!
  ( sleep "$timeout_sec"; kill -0 "$test_pid" 2>/dev/null && kill -TERM "$test_pid" 2>/dev/null ) &
  local watcher_pid=$!
  wait "$test_pid" 2>/dev/null
  rc=$?
  # Stop the watcher if the test finished first.
  kill -TERM "$watcher_pid" 2>/dev/null; wait "$watcher_pid" 2>/dev/null
  # A killed test returns 143 (128+SIGTERM); normalize to 124 so the timeout branch below fires.
  [ $rc -eq 143 ] && rc=124
  set -e
  end=$(date +%s)
  elapsed=$((end - start))

  if [ $rc -eq 0 ]; then
    log_pass "$name (${elapsed}s)"
    RESULTS+=("PASS|$name|${elapsed}s")
    PASS_COUNT=$((PASS_COUNT + 1))
  elif [ $rc -eq 124 ]; then
    log_fail "$name (TIMEOUT after ${timeout_sec}s)"
    RESULTS+=("FAIL|$name|TIMEOUT")
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    log_fail "$name (exit $rc, ${elapsed}s)"
    RESULTS+=("FAIL|$name|exit $rc")
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  return $rc
}

skip_test() {
  local name="$1" reason="$2"
  log_skip "$name — $reason"
  RESULTS+=("SKIP|$name|$reason")
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

print_summary() {
  echo ""
  echo "=============================="
  echo " Test Summary"
  echo "=============================="
  printf "%-8s %-35s %s\n" "STATUS" "TEST" "DETAIL"
  echo "--------------------------------------------------------------"
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r status name detail <<< "$r"
    printf "%-8s %-35s %s\n" "$status" "$name" "$detail"
  done
  echo "--------------------------------------------------------------"
  printf "PASS: %d  FAIL: %d  SKIP: %d  TOTAL: %d\n" \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" \
    $((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
  echo ""
}

wait_for_pod() {
  local ns="$1" name="$2" phase="$3" timeout_sec="${4:-120}"
  local deadline=$(($(date +%s) + timeout_sec))
  while true; do
    local current
    current=$(kubectl get pod "$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$current" = "$phase" ] && return 0
    [ "$current" = "Failed" ] && return 1
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 5
  done
}

wait_for_job() {
  local ns="$1" name="$2" timeout_sec="${3:-300}"
  local deadline=$(($(date +%s) + timeout_sec))
  # Select the Complete/Failed condition by TYPE, not by array index. Kubernetes 1.32+ adds a
  # separate "SuccessCriteriaMet" condition that can occupy conditions[0], so a hardcoded
  # conditions[0].type never equals "Complete" and the wait times out on an already-done Job.
  while true; do
    local complete failed
    complete=$(kubectl get job "$name" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")
    failed=$(kubectl get job "$name" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
    [ "$complete" = "True" ] && return 0
    [ "$failed" = "True" ] && return 1
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 5
  done
}
