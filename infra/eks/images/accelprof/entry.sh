#!/bin/sh
# Wraps a workload command so that a profile is captured and the outcome is recorded, without the
# workload's image having to know anything about the profiling platform.
#
# The contract with the workload is one directory. Whatever it writes there is recorded:
#   $ACCELPROF_OUT/metrics.json   optional, a flat JSON object of numbers
#   $ACCELPROF_OUT/params.json    optional, a flat JSON object
#   $ACCELPROF_OUT/tags.json      optional, a flat JSON object of strings
#   $ACCELPROF_OUT/artifacts/     optional, any files to keep alongside the profile
#   $ACCELPROF_OUT/traces/        written here by this script
#   $ACCELPROF_OUT/status.json    written here by this script, the recorder's start signal
#
# POSIX sh on purpose: a workload image is not guaranteed to have bash.
set -u

out="${ACCELPROF_OUT:-/accelprof/out}"
mkdir -p "${out}/traces" "${out}/artifacts"

rank="${ACCELPROF_NODE_RANK:-${JOB_COMPLETION_INDEX:-0}}"
ranks="${ACCELPROF_PROFILE_RANKS:-0}"
mode="${ACCELPROF_PROFILE_MODE:-none}"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# status.json is written on every exit path this process can observe, including a signal, so the
# recorder is not left waiting on a workload that died. A SIGKILL (OOM) cannot be trapped; the
# recorder covers that case by watching the container's own status.
write_status() {
  code="$1"; reason="$2"
  cat >"${out}/status.json" <<STATUS
{"schema_version": 1,
 "exit_code": ${code}, "reason": "${reason}", "started_at": "${started}",
 "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "node_rank": "${rank}",
 "profiled": ${3:-false}, "pod": "${ACCELPROF_POD_NAME:-}"}
STATUS
}
on_signal() { write_status 143 terminated "${profiled:-false}"; exit 143; }
trap on_signal HUP INT TERM

# Is this rank one of the ranks being profiled? Profiling every rank of a large job multiplies the
# capture cost, so the default samples rank 0. "all" profiles every rank.
profile_this_rank() {
  [ "${mode}" = "none" ] && return 1
  [ "${ranks}" = "all" ] && return 0
  for r in $(echo "${ranks}" | tr ',' ' '); do
    [ "${r}" = "${rank}" ] && return 0
  done
  return 1
}

profiled=false
if profile_this_rank; then
  case "${mode}" in
    nsys)
      # The tools directory is populated by the init container when tool injection is on; an image
      # that already ships nsys is used as-is.
      if [ -d "${ACCELPROF_TOOLS:-/accelprof/tools}/nsys" ]; then
        PATH="${ACCELPROF_TOOLS:-/accelprof/tools}/nsys:$(dirname "${ACCELPROF_TOOLS:-/accelprof/tools}")/tools/nsys/target-linux-x64:${PATH}"
        export PATH
      fi
      if command -v nsys >/dev/null 2>&1; then
        profiled=true
        # shellcheck disable=SC2086
        nsys profile ${ACCELPROF_NSYS_ARGS:--t cuda,nvtx,osrt} \
          -o "${out}/traces/rank-${rank}" --force-overwrite true "$@"
        code=$?
      else
        echo "accelprof: nsys not found; running without a profile" >&2
        "$@"; code=$?
      fi
      ;;
    neuron)
      # Neuron capture needs the device and the compiled artifact, so the workload itself drives
      # neuron-explorer and leaves its output in the traces directory. Nothing to wrap here.
      profiled=true
      "$@"; code=$?
      ;;
    *)
      echo "accelprof: unknown profile mode '${mode}'; running without a profile" >&2
      "$@"; code=$?
      ;;
  esac
else
  "$@"; code=$?
fi

write_status "${code}" "$([ "${code}" -eq 0 ] && echo completed || echo failed)" "${profiled}"
exit "${code}"
