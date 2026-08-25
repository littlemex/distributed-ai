#!/usr/bin/env bash
# run-render-tests.sh — check what the profiling client renders, without a cluster.
#
# Separate from run-tests.sh on purpose: that suite exercises a live cluster, so it is slow, needs
# credentials and a namespace, and fails for environmental reasons. This one only renders a manifest
# and compares it to a golden file, so it belongs in the fast lane of CI and can gate every commit.
#
#   infra/eks/tests/run-render-tests.sh            compare against the golden manifest
#   infra/eks/tests/run-render-tests.sh --update   rewrite the golden manifest after an intended change
#
# The golden file is what makes a change to the embedded Job shape visible in review: the shape lives
# inside the client so that the client stays a single distributable file, and without a golden file a
# reviewer would have to read a heredoc diff to see what changed in the manifest.
set -euo pipefail

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
eks_dir="$(cd "${tests_dir}/.." && pwd)"
client="${eks_dir}/bin/kubectl-accelprof"
golden="${tests_dir}/golden/profiling-producer.job.yaml"
update=false
[ "${1:-}" = "--update" ] && update=true

# Fixed inputs, so the only thing that can change the output is the client itself. The image is a
# placeholder rather than a real digest: this test must not depend on an account or a registry.
render() {
  ACCELPROF_PLATFORM_IMAGE="image.example/accelprof@sha256:$(printf '0%.0s' $(seq 64))" \
  KUBE_CONTEXT="" "${client}" run \
    --alias tenant-series \
    --namespace producer-namespace \
    --image image.example/workload:tag \
    --dry-run \
    -- python train.py --lr=3e-4 |
    # The workload id carries a timestamp and random suffix, which would make every run differ.
    sed -E 's/(wl-)[0-9]{12}-[0-9a-f]{8}/\1000000000000-00000000/g'
}

[ -x "${client}" ] || { printf 'error: %s is not executable\n' "${client}" >&2; exit 1; }

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
render >"${tmp}"

if [ ! -s "${tmp}" ]; then
  printf 'error: the client rendered nothing\n' >&2
  exit 1
fi

if [ "${update}" = true ]; then
  cp "${tmp}" "${golden}"
  printf 'updated %s\n' "${golden}"
  exit 0
fi

if diff -u "${golden}" "${tmp}"; then
  printf 'render test: the manifest matches %s\n' "${golden##*/}"
else
  printf '\nerror: the rendered manifest differs from the golden file above.\n' >&2
  printf 'If the change is intended, re-run with --update and include the golden diff in review.\n' >&2
  exit 1
fi
