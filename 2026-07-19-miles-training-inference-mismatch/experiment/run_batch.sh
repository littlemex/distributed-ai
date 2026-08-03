#!/usr/bin/env bash
# Batch entry point. Sources the driver library by absolute path derived from this
# script's own location: a relative `source lib/experiment.sh` after a `cd` picks up
# whatever copy happens to sit in the working directory, which is how a stale library
# once ran in place of the reviewed one.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${RUN_DIR:-$SCRIPT_DIR}" || { echo "FATAL: cd ${RUN_DIR:-$SCRIPT_DIR} failed" >&2; exit 1; }

source "$SCRIPT_DIR/lib/experiment.sh" || exit 1
exp_init || exit 1
exp_run_cells "$@"
