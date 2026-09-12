#!/usr/bin/env bash
# Prepare the environment, then hand the arguments straight to the harness.
#
# The upstream benchmark is cloned at a pinned commit rather than tracked by
# branch. Its datasets and its scorer produced the numbers, so "which commit" is
# part of the result; a floating branch would make a run unreproducible without
# anyone noticing.
set -euo pipefail

: "${UPSTREAM_REPO:?}" "${UPSTREAM_COMMIT:?}" "${RESULTS_DIR:?}"

WORK=/opt/bench/work
UPSTREAM="$WORK/semantic-router"
VENV="$WORK/venv"

mkdir -p "$WORK" "$RESULTS_DIR" "${HF_HOME:-/tmp/hf}" "${PIP_CACHE_DIR:-/tmp/pip}"
echo "[INFO] $(date -u +%FT%TZ) preparing"

if ! command -v git >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq --no-install-recommends git ca-certificates
fi

# Only bench/ is needed, so fetch one commit and check out one directory.
if [ ! -d "$UPSTREAM/bench/reasoning" ]; then
  rm -rf "$UPSTREAM"
  git init -q "$UPSTREAM"
  git -C "$UPSTREAM" remote add origin "$UPSTREAM_REPO"
  git -C "$UPSTREAM" config core.sparseCheckout true
  echo "bench/" > "$UPSTREAM/.git/info/sparse-checkout"
  git -C "$UPSTREAM" fetch -q --depth 1 origin "$UPSTREAM_COMMIT"
  git -C "$UPSTREAM" checkout -q FETCH_HEAD
fi
echo "[INFO] upstream bench at $(git -C "$UPSTREAM" rev-parse --short HEAD)"

if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
fi
"$VENV/bin/pip" install -q \
  aiohttp pyyaml pandas numpy datasets matplotlib seaborn tqdm openai scipy

# The ConfigMap mounts are read-only and Python writes bytecode beside its
# sources, so the tree is copied out rather than run in place. The layout mirrors
# the repository: `harness/catalog.py` reaches ../../vsr/build_config.py, which is
# how the harness and the router stay on a single copy of the roster and the rates.
rm -rf "$WORK/bench" "$WORK/vsr"
mkdir -p "$WORK/bench/harness" "$WORK/vsr"
cp /opt/bench/src/*.py /opt/bench/src/*.json "$WORK/bench/" 2>/dev/null || true
cp /opt/bench/src/harness/*.py "$WORK/bench/harness/"
mv "$WORK/bench/build_config.py" "$WORK/vsr/build_config.py"
cp /opt/bench/src/pool.yaml "$WORK/vsr/pool.yaml"
mkdir -p "$WORK/defaults"
mv "$WORK/bench/models.json" "$WORK/bench/pricing.json" "$WORK/defaults/"

export VSR_BENCH_ROOT="$UPSTREAM/bench"
export STRATOCLAVE_DEFAULTS="$WORK/defaults"
export PYTHONUNBUFFERED=1

cd "$WORK/bench"

# Resume is the only safe default for a Job that can be retried: an attempt that
# was killed mid-run has already been billed for the cells it wrote, and starting
# over would buy them a second time. On a first attempt there is nothing to skip,
# so this changes nothing. Only the collecting subcommands accept it.
resume=()
case "${1:-}" in
  matrix|routed|mixed|repeat) resume=(--resume) ;;
esac

echo "[INFO] $(date -u +%FT%TZ) starting: $*"
exec "$VENV/bin/python" collect.py "$@" \
  "${resume[@]}" \
  --pool "$WORK/vsr/pool.yaml" \
  --out-dir "$RESULTS_DIR"
