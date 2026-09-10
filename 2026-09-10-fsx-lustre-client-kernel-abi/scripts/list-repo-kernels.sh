#!/usr/bin/env bash
# List the kernel releases for which the FSx for Lustre Ubuntu repository publishes a
# binary client module, grouped by Ubuntu suite and architecture.
#
# The published set differs per suite, so a kernel release that is missing from one
# suite can still be present in another. Reading the repository index answers that
# question without provisioning an instance.
#
# Usage:
#   ./list-repo-kernels.sh                       # focal, jammy, noble on amd64
#   ARCH=arm64 ./list-repo-kernels.sh            # same suites on arm64
#   ./list-repo-kernels.sh jammy noble           # selected suites

set -euo pipefail

REPO_BASE="${REPO_BASE:-https://fsx-lustre-client-repo.s3.amazonaws.com/ubuntu}"
ARCH="${ARCH:-amd64}"
SUITES=("$@")
if [[ ${#SUITES[@]} -eq 0 ]]; then
    SUITES=(focal jammy noble)
fi

for suite in "${SUITES[@]}"; do
    index_url="${REPO_BASE}/dists/${suite}/main/binary-${ARCH}/Packages"
    if ! index=$(curl -fsSL "${index_url}"); then
        echo "== ${suite} (${ARCH}): index not available at ${index_url}"
        continue
    fi
    echo "== ${suite} (${ARCH})"
    printf '%s\n' "${index}" | python3 -c '
import collections
import re
import sys

series = collections.defaultdict(set)
for line in sys.stdin:
    match = re.match(r"^Package: lustre-client-modules-(\d+\.\d+)\.0-(\d+)-aws(-64k)?$", line.strip())
    if match:
        series[(match.group(1), match.group(3) or "")].add(int(match.group(2)))

def key(flavour):
    return tuple(int(part) for part in flavour[0].split(".")), flavour[1]

for flavour in sorted(series, key=key):
    builds = sorted(series[flavour])
    label = flavour[0] + ".0" + flavour[1]
    print(f"   kernel {label:<12} builds: {len(builds):<4} highest ABI: {builds[-1]}")
'
    echo
done
