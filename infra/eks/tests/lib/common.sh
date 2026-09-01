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

tf_console() {
  "$SCRIPT_DIR/../scripts/tf-console.sh" "$SCRIPT_DIR/.." "$1"
}

tf_console_fixture() {
  "$SCRIPT_DIR/../scripts/tf-console.sh" "$SCRIPT_DIR/.." -var-file=tests/fixtures/accelerator-pools.tfvars "$1"
}

run_test() {
  local name="$1" timeout_sec="$2" func="$3"
  local start end elapsed rc
  start=$(date +%s)
  set +e
  # Enforce timeout_sec by running the test in its own process group and killing the whole group on
  # deadline — a hung kubectl/aws child is terminated too, not just the subshell (orphaned mutating
  # calls must not fire after teardown). `set -m` makes the backgrounded job a process-group leader
  # on bash 3.2 (macOS) and Linux alike; the fence is closed immediately so job-control side effects
  # do not leak. The test keeps this shell's functions/vars (aws_cmd, apply_manifest, ...).
  set -m
  ( set -e; $func ) &
  local test_pid=$!
  set +m
  ( sleep "$timeout_sec"; kill -0 "$test_pid" 2>/dev/null && kill -TERM -- -"$test_pid" 2>/dev/null ) &
  local watcher_pid=$!
  wait "$test_pid" 2>/dev/null
  rc=$?
  # Stop the watcher if the test finished first.
  kill -TERM "$watcher_pid" 2>/dev/null; wait "$watcher_pid" 2>/dev/null
  set -e
  end=$(date +%s)
  elapsed=$((end - start))
  # A watchdog-killed test returns 143 (128+SIGTERM); map to 124 (timeout) only when the deadline
  # actually elapsed, so a test failing via an unrelated SIGTERM is not mislabeled as a timeout.
  if [ "$rc" -eq 143 ] && [ "$elapsed" -ge "$timeout_sec" ]; then rc=124; fi

  if [ $rc -eq 0 ]; then
    log_pass "$name (${elapsed}s)"
    RESULTS+=("PASS|$name|${elapsed}s")
    PASS_COUNT=$((PASS_COUNT + 1))
  elif [ $rc -eq 2 ]; then
    log_skip "$name — not applicable (${elapsed}s)"
    RESULTS+=("SKIP|$name|not applicable")
    SKIP_COUNT=$((SKIP_COUNT + 1))
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
  # Guard empty-array expansion: on bash 3.2 (macOS) under `set -u`, "${RESULTS[@]}" is an unbound
  # variable error when no test ran (e.g. every layer skipped).
  for r in ${RESULTS[@]+"${RESULTS[@]}"}; do
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

# The region an EKS kubeconfig points at, or empty. Read from the cluster entry rather than the context
# name: `aws eks update-kubeconfig --alias <name>` renames the context to something short (the workshop
# preamble names it after the cluster), and only the cluster entry keeps the ARN that carries the
# region. The context name is still tried, for a kubeconfig written without an alias.
eks_region_from_kubeconfig() {
  local from_arn
  from_arn="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null |
    sed -n 's|^arn:aws[a-z-]*:eks:\([a-z0-9-]*\):.*|\1|p')"
  [ -n "$from_arn" ] || from_arn="$(kubectl config current-context 2>/dev/null |
    sed -n 's|^arn:aws[a-z-]*:eks:\([a-z0-9-]*\):.*|\1|p')"
  printf '%s' "$from_arn"
}

# Run a command string in the named shell with this run's AWS profile in the environment. Two mistakes
# are avoided here, and both were made. Passing AWS_PROFILE='' is not "no profile" to the AWS CLI: it
# looks for a profile named "" and fails, with a message about credentials or the resource rather than
# the empty string, so every run without --profile used to source distai-env.sh with an empty profile
# and the failure looked like a broken registry. And the fix for that must not interpolate the value
# into the command string, because a value spliced into shell text is shell code: a profile name
# containing a quote breaks the assignment and one containing `;` runs. env passes it as data, which
# nothing inside the string can reach. `-u` when there is no profile, so an empty one in the harness's
# own environment is not inherited either.
run_in_shell() {
  local shell="$1" cmd="$2"
  # Start from a shell that has read no startup files. A developer whose ~/.zshenv or BASH_ENV exports a
  # profile would otherwise re-poison the child after the harness cleared it, which would make these
  # results depend on whose machine ran them. Word splitting here is deliberate.
  local pristine=""
  case "$shell" in
    *zsh)  pristine="-f" ;;
    *bash) pristine="--noprofile --norc" ;;
  esac
  # AWS_DEFAULT_PROFILE travels with AWS_PROFILE: the v1 CLI and boto3 read it, so clearing only one of
  # them leaves the same defect available under the other name.
  if [ -n "${AWS_PROFILE_OPT:-}" ]; then
    env -u AWS_DEFAULT_PROFILE -u BASH_ENV -u ENV AWS_PROFILE="${AWS_PROFILE_OPT}" \
      "$shell" $pristine -c "$cmd"
  else
    env -u AWS_PROFILE -u AWS_DEFAULT_PROFILE -u BASH_ENV -u ENV "$shell" $pristine -c "$cmd"
  fi
}
