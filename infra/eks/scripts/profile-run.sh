#!/usr/bin/env bash
# Deprecated: superseded by scripts/kubectl-profile, which needs only kubectl and returns as soon as
# the run is submitted (recording happens in the cluster, so nothing local has to stay alive).
#
#   kubectl profile run --alias team1-lora-sweep --image <your image> -- python train.py
#
# This wrapper forwards to it for one release so existing invocations keep working.
set -euo pipefail
printf 'warning: profile-run.sh is deprecated; use kubectl-profile (kubectl profile run ...)\n' >&2
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kubectl-profile" run "$@"
