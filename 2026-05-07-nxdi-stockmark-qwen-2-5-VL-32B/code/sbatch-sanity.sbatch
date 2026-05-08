#!/bin/bash
#SBATCH --job-name=stockmark-docreasoner-sanity
#SBATCH --partition=compute-trn2
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=0:30:00
#SBATCH --chdir=/home/ubuntu

# Multi-prompt sanity (3 English + 3 Japanese), reuses pre-compiled 64L NEFF.
# Reports HF CPU text vs NxD text per prompt and a degeneracy check
# (6 consecutive identical tokens => broken).
#
# Required:
#   HF_TOKEN, EXP_DIR
#   Pre-existing $EXP_DIR/traces/nxd-64l/model.pt from sbatch-compile-full.sbatch

export PATH=/opt/neuron_venv/bin:/opt/aws/neuron/bin:$PATH
export HF_HUB_DISABLE_XET=1
export HF_HUB_ENABLE_HF_TRANSFER=1
export NEURON_LOGICAL_NC_CONFIG=1
export NEURON_RT_VISIBLE_CORES=0-7
export NEURON_RT_NUM_CORES=8

: "${HF_TOKEN:?set HF_TOKEN before sbatch submit}"
: "${EXP_DIR:?set EXP_DIR to the dir containing code/}"
export HF_TOKEN EXP_DIR

echo "=== Job start: $(date -u +%FT%TZ) ==="
source /opt/neuron_venv/bin/activate

TS=$(date -u +%Y%m%dT%H%M%S)
export NEURON_COMPILE_CACHE_URL=/home/ubuntu/neuron-cache-stockmark-sanity-${TS}
mkdir -p "$NEURON_COMPILE_CACHE_URL"

python "$EXP_DIR/code/sanity_generate.py" 2>&1 | tee "$EXP_DIR/results/sanity-run.out"
RC=$?

echo "=== SUMMARY ==="
cat "$EXP_DIR/results/sanity-generate.json" 2>/dev/null
echo "=== Job end: $(date -u +%FT%TZ) RC=$RC ==="
exit $RC
