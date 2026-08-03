#!/usr/bin/env bash
# Shared experiment driver library for the mismatch study.
#
# WHY THIS EXISTS. Earlier ad-hoc drivers wrote logs and result lines under /tmp on the
# Ray head pod, which is periodically reclaimed. Several completed runs lost their
# results even though the Ray job itself had succeeded, and the raw job logs went with
# them. Anything worth keeping has to land on shared storage, and every path has to come
# from a variable so the same driver runs on another cluster without edits.
#
# It also exists because a previous batch was reported as complete when no job had been
# submitted at all. A driver that cannot tell "ran and produced a number" from "never
# ran" is worse than no driver: it manufactures results. So every terminal state here is
# explicit (SUCCEEDED / FAILED / STOPPED / NO_JOB / TIMEOUT), a cell with no job never
# gets a metric column, and the run's identity (job id, env file, code hash) is written
# next to the numbers so any row can be traced back to its evidence.
#
# Nothing here is tied to a GPU type, namespace, model or cluster: all of that arrives
# via the environment, so this file is safe to lift into the upstream test case as-is.
#
# REQUIRED (normally exported by the per-experiment env file):
#   EXP_ROOT   directory on shared storage for logs and results (e.g. /fsx/exp)
#   EXP_NAME   name of this batch; artefacts land in $EXP_ROOT/$EXP_NAME/
#
# OPTIONAL:
#   RUN_DIR      working dir holding recipe/ and the env files (default: cwd)
#   RECIPE       recipe to invoke, relative to RUN_DIR (default: the 4B GRPO recipe)
#   ENV_PREFIX   prefix prepended to a cell name to form its env filename
#   EXP_POLL     seconds between job status polls (default 30)
#   EXP_TIMEOUT  seconds to wait for a job before giving up (default 14400 = 4h)
#
# Usage:
#   source /abs/path/to/lib/experiment.sh   # absolute: a relative source picks up
#   exp_init                                # whatever stale copy sits in the cwd
#   exp_run_cells cell_a cell_b ...

set -u

# Metrics pulled from every job log, in results.tsv column order. Editing this list
# changes the schema, so change EXP_NAME too (see exp_init's schema guard).
EXP_METRIC_KEYS=(
  'train/mis_kl'
  'train/mis_chi2_token'
  'train/ppo_kl'
  'train/train_rollout_logprob_abs_diff'
  'train/grad_norm'
  'rollout/raw_reward'
)
EXP_METRIC_COLS=(mis_kl chi2_token ppo_kl abs_diff grad_norm reward)

exp_init() {
  : "${EXP_ROOT:?EXP_ROOT must be set (shared-storage dir for results)}"
  : "${EXP_NAME:?EXP_NAME must be set: the name of this batch}"
  # A relative EXP_ROOT would resolve against whatever cwd the driver happened to be
  # started from, and an EXP_NAME with a slash would silently nest the batch somewhere
  # unexpected. Both have bitten us, so fail loudly instead.
  case "$EXP_ROOT" in
    /*) ;;
    *) echo "FATAL: EXP_ROOT must be an absolute path: $EXP_ROOT" >&2; return 1 ;;
  esac
  case "$EXP_NAME" in
    */*|.|..) echo "FATAL: EXP_NAME must be a plain name: $EXP_NAME" >&2; return 1 ;;
  esac

  RUN_DIR="${RUN_DIR:-$(pwd)}"
  RECIPE="${RECIPE:-recipe/run_grpo_qwen3_4b.sh}"
  EXP_POLL="${EXP_POLL:-30}"
  EXP_TIMEOUT="${EXP_TIMEOUT:-14400}"
  EXP_DIR="$EXP_ROOT/$EXP_NAME"
  EXP_RESULTS="$EXP_DIR/results.tsv"
  EXP_LOG="$EXP_DIR/driver.log"
  mkdir -p "$EXP_DIR/joblogs" "$EXP_DIR/env" || return 1

  local header="cell	run_ts	status	job_id"
  local c
  for c in "${EXP_METRIC_COLS[@]}"; do header+="	$c"; done
  if [ ! -f "$EXP_RESULTS" ]; then
    printf '%s\n' "$header" > "$EXP_RESULTS"
  else
    # A schema change mid-batch would interleave rows with different column meanings,
    # which is unreadable later. Refuse rather than append.
    local existing
    existing=$(head -1 "$EXP_RESULTS")
    if [ "$existing" != "$header" ]; then
      echo "FATAL: $EXP_RESULTS has a different schema; use a new EXP_NAME." >&2
      echo "  existing: $existing" >&2
      echo "  expected: $header" >&2
      return 1
    fi
  fi

  # Record which code actually ran. The point of this line is that a results.tsv can be
  # audited later without trusting anyone's memory of what was deployed.
  local lib_sha
  lib_sha=$(sha256sum "${BASH_SOURCE[0]}" 2>/dev/null | cut -c1-12)
  exp_log "init EXP_DIR=$EXP_DIR RECIPE=$RECIPE RUN_DIR=$RUN_DIR lib_sha=${lib_sha:-NA}"
  # Environment provenance: after the Capacity Block ends this is the only proof of what
  # the hardware was.
  {
    echo "# captured by exp_init at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv 2>/dev/null
    echo "--- fi_info ---"; fi_info -p efa 2>/dev/null | grep -E 'provider|domain' | head
  } > "$EXP_DIR/environment.txt" 2>/dev/null || true
}

exp_log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg" | tee -a "${EXP_LOG:-/dev/null}"
}

# Pull one scalar metric from a job log FILE (not a shell variable: multi-MB logs in a
# variable lose trailing newlines and NUL bytes, and this log is primary data).
# $1 = path to log file, $2 = metric key exactly as it appears (e.g. train/mis_kl)
#
# The log format is a printed python dict, so a key appears as  'train/mis_kl': 0.00061
# Anchoring on the closing quote and colon is what keeps train/mis_kl from also matching
# a longer key that starts with it. nan/inf are matched explicitly: a diverged run
# prints those, and letting the number pattern fail silently turns a real datum into a
# missing one.
_exp_metric() {
  local file="$1" key="$2" key_re
  [ -f "$file" ] || { printf '%s\n' '-'; return 0; }
  key_re=$(printf '%s' "$key" | sed -e 's/[][\/.^$*+?(){}|]/\\&/g')
  local v
  v=$(grep -oE "'${key_re}': (-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?|-?[iI]nf|-?nan)" "$file" \
      | tail -1 | sed -E "s/^'${key_re}': //")
  printf '%s\n' "${v:--}"
}

# Block until a Ray job reaches a terminal state. Echoes the terminal status, or
# TIMEOUT / UNKNOWN.
#
# The status comes from the Python SDK, not from `ray job status` text. The CLI prints
# "Job 'x' failed" wrapped in ANSI colour codes and then a "Status message:" block that
# itself contains words like "failed" -- verified against a real failed job here, where a
# naive grep matches the message instead of the status. The SDK returns the enum.
# "cannot reach the dashboard" and "reached it, no such job" are different facts and are
# reported separately: the first is a transient worth retrying briefly, the second is
# terminal. Collapsing both into one UNKNOWN made a dead head cost a full EXP_TIMEOUT per
# cell.
_exp_job_status() {
  python3 - "$1" <<'PY' 2>/dev/null
import os, sys
addr = os.environ.get("RAY_DASHBOARD_ADDRESS", "http://127.0.0.1:8265")
try:
    from ray.job_submission import JobSubmissionClient
    print(str(JobSubmissionClient(addr).get_job_status(sys.argv[1])))
except Exception as e:
    m = str(e).lower()
    print("NOT_FOUND" if ("does not exist" in m or "not found" in m) else "UNREACHABLE")
PY
}

_exp_wait_job() {
  local job_id="$1" waited=0 st bad=0 nf=0
  while :; do
    st=$(_exp_job_status "$job_id")
    case "$st" in
      SUCCEEDED|FAILED|STOPPED) printf '%s\n' "$st"; return 0 ;;
      NOT_FOUND)
        # Tolerate one transient miss right after submit, then believe it.
        nf=$((nf + 1))
        [ "$nf" -ge 2 ] && { printf '%s\n' NOT_FOUND; return 0; } ;;
      UNREACHABLE|"")
        # A dead head should cost minutes, not EXP_TIMEOUT, and certainly not once per cell.
        bad=$((bad + 1))
        [ "$bad" -ge 10 ] && { printf '%s\n' UNKNOWN; return 0; } ;;
      *) bad=0; nf=0 ;;
    esac
    if [ "$waited" -ge "$EXP_TIMEOUT" ]; then
      printf '%s\n' TIMEOUT; return 0
    fi
    sleep "$EXP_POLL"
    waited=$((waited + EXP_POLL))
  done
}

# Append one row. Metrics are only ever passed in for a job that reached a terminal
# state; every other path writes '-' in all metric columns, so a number in this file
# always means a job produced it.
_exp_row() {
  local cell="$1" ts="$2" status="$3" job_id="$4" logfile="${5:-}"
  local row="$cell	$ts	$status	$job_id" key
  for key in "${EXP_METRIC_KEYS[@]}"; do
    if [ -n "$logfile" ]; then
      row+="	$(_exp_metric "$logfile" "$key")"
    else
      row+="	-"
    fi
  done
  printf '%s\n' "$row" >> "$EXP_RESULTS"
}

exp_run_cells() {
  local cell env_file job_id status ts joblog
  # Zero cells is never intentional: it means the generator or the caller's cell list is
  # empty, and printing "batch complete" for it is how an empty batch reads as a done one.
  if [ "$#" -eq 0 ]; then
    exp_log "FATAL: exp_run_cells called with no cells"
    return 1
  fi
  for cell in "$@"; do
    env_file="$RUN_DIR/${ENV_PREFIX:-}${cell}"
    # A missing env file used to be skipped with a warning. But the generator failing to
    # write anything is exactly how a batch silently produced zero cells before, so a
    # missing env is fatal: it means the batch is not the batch that was intended.
    if [ ! -f "$env_file" ]; then
      exp_log "FATAL $cell: env file not found: $env_file"
      return 1
    fi

    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # Freeze what was submitted next to what came out of it.
    cp "$env_file" "$EXP_DIR/env/${cell}.env" 2>/dev/null || true
    exp_log "start $cell"

    # The recipe calls `ray job submit` without --no-wait, so it blocks here until the
    # job is terminal. That implicit wait is the one that has to be bounded: a hung job
    # (NCCL stall, engine deadlock) would otherwise consume the rest of the Capacity
    # Block in silence, and the explicit _exp_wait_job below would never be reached.
    local rc=0
    ( cd "$RUN_DIR" && ENV_FILE="$env_file" \
        timeout --kill-after=60 "$EXP_TIMEOUT" bash "$RECIPE" ) \
      > "$EXP_DIR/joblogs/${cell}.submit.log" 2>&1 || rc=$?

    # -a: the submit log carries ANSI escapes, and grep treats such a file as binary and
    # prints nothing, which would look exactly like "no job was submitted".
    job_id=$(grep -aoE 'raysubmit_[A-Za-z0-9]+' "$EXP_DIR/joblogs/${cell}.submit.log" \
             | tail -1)

    if [ "$rc" -eq 124 ]; then
      # Killing the recipe does not kill the Ray job. Stop it, or the TIMEOUT row points
      # at a job that may later succeed, and the orphan keeps its GPUs and makes the next
      # cell time out too.
      if [ -n "$job_id" ]; then
        ray job stop "$job_id" >/dev/null 2>&1 || true
        exp_log "TIMEOUT $cell: recipe exceeded ${EXP_TIMEOUT}s; stopped job $job_id"
        _exp_row "$cell" "$ts" TIMEOUT "$job_id" ""
      else
        exp_log "TIMEOUT $cell: recipe exceeded ${EXP_TIMEOUT}s; no job id found"
        _exp_row "$cell" "$ts" NO_JOB - ""
      fi
      continue
    fi

    if [ -z "$job_id" ]; then
      exp_log "NO_JOB $cell: recipe never submitted; see joblogs/${cell}.submit.log"
      _exp_row "$cell" "$ts" NO_JOB - ""
      continue
    fi
    # Record the job id before waiting: if this driver dies, the id is how the run is
    # recovered, and it must not live only inside a log we might not find.
    exp_log "submitted $cell job=$job_id"

    status=$(_exp_wait_job "$job_id")
    joblog="$EXP_DIR/joblogs/${cell}.job.log"
    ray job logs "$job_id" > "$joblog" 2>"$EXP_DIR/joblogs/${cell}.job.err" || true

    if [ "$status" = SUCCEEDED ]; then
      # If `ray job logs` came back empty (head restart, GC), fall back to the submit log:
      # the recipe streams the job's whole output there. Otherwise a SUCCEEDED row would
      # carry all '-' and be indistinguishable from a run that printed no metrics.
      if [ ! -s "$joblog" ]; then
        exp_log "WARN $cell: ray job logs empty; falling back to streamed submit.log"
        joblog="$EXP_DIR/joblogs/${cell}.submit.log"
      fi
      _exp_row "$cell" "$ts" "$status" "$job_id" "$joblog"
      exp_log "done $cell status=$status job=$job_id mis_kl=$(_exp_metric "$joblog" 'train/mis_kl')"
    else
      # A non-SUCCEEDED job may still have printed plausible mid-run metrics. Writing
      # them would make a crashed cell indistinguishable from a clean one, so withhold.
      _exp_row "$cell" "$ts" "$status" "$job_id" ""
      exp_log "done $cell status=$status job=$job_id (metrics withheld: not SUCCEEDED)"
    fi
  done
  exp_log "batch complete: $EXP_RESULTS"
}

# Latest attempt per cell, for analysis. Re-running a batch appends, so the raw file can
# hold several rows for one cell; this is the documented way to read it.
exp_latest() {
  local f="${1:-$EXP_RESULTS}"
  { head -1 "$f"; tail -n +2 "$f" | tac | awk -F'\t' '!seen[$1]++' | tac; }
}
