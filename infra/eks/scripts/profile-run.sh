#!/usr/bin/env bash
# Deprecated: superseded by scripts/kubectl-accelprof, which needs only kubectl and returns as soon as
# the run is submitted (recording happens in the cluster, so nothing local has to stay alive).
#
#   kubectl accelprof run --alias team1-lora-sweep --image <your image> -- python train.py
#
# This wrapper forwards to it so existing invocations keep working. Delete it after 2026-10-01;
# the date is in the warning so that it is visible on every run rather than only in this comment.
set -euo pipefail
printf 'warning: profile-run.sh is deprecated and will be deleted after 2026-10-01; use kubectl-accelprof (kubectl accelprof run ...)\n' >&2
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/kubectl-accelprof" run "$@"
