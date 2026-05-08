#!/bin/bash
#SBATCH --job-name=stockmark-docreasoner-full64
#SBATCH --partition=compute-trn2
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=5:00:00
#SBATCH --chdir=/home/ubuntu

# Full 64-layer compile. Use AFTER smoke 1-layer reports probe_cos > 0.99.
# Expected wall time (trn2.3xlarge, TP=8, seq_len=128+16):
#   HF save_pretrained (from HF cache):  ~1-2 min
#   NxD compile (CTE + TKG):             ~5 min
#   TP=8 shard load:                     ~70 sec
#   forward:                             < 1 sec
# Disk footprint on /home: ~150 GB (64-layer HF snapshot ~63 GB + NEFF caches).

export PATH=/opt/neuron_venv/bin:/opt/aws/neuron/bin:$PATH
export HF_HUB_DISABLE_XET=1
export HF_HUB_ENABLE_HF_TRANSFER=1
export NEURON_LOGICAL_NC_CONFIG=1
export NEURON_RT_VISIBLE_CORES=0-7
export NEURON_RT_NUM_CORES=8

: "${HF_TOKEN:?set HF_TOKEN before sbatch submit}"
: "${EXP_DIR:?set EXP_DIR to the dir containing code/compile_and_test.py}"
export HF_TOKEN EXP_DIR
export NUM_LAYERS=64

mkdir -p "$EXP_DIR/results" "$EXP_DIR/traces"

echo "=== Job start: $(date -u +%FT%TZ) NUM_LAYERS=$NUM_LAYERS ==="
source /opt/neuron_venv/bin/activate

python -c "import neuronx_distributed_inference" 2>/dev/null || {
    sudo /opt/neuron_venv/bin/pip install --quiet --disable-pip-version-check \
        --extra-index-url https://pip.repos.neuron.amazonaws.com \
        "torch_neuronx>=2.9,<2.10" 2>&1 | tail -5
    sudo rm -rf /tmp/nxd /tmp/nxdi
    git clone --depth 1 https://github.com/aws-neuron/neuronx-distributed.git /tmp/nxd 2>&1 | tail -2
    sudo /opt/neuron_venv/bin/pip install --quiet --disable-pip-version-check /tmp/nxd 2>&1 | tail -5
    git clone --depth 1 https://github.com/aws-neuron/neuronx-distributed-inference.git /tmp/nxdi 2>&1 | tail -2
    sudo /opt/neuron_venv/bin/pip install --quiet --disable-pip-version-check \
        --extra-index-url https://pip.repos.neuron.amazonaws.com /tmp/nxdi 2>&1 | tail -10
}
python -c "from transformers import Qwen2_5_VLForConditionalGeneration" 2>/dev/null || {
    sudo /opt/neuron_venv/bin/pip install --quiet --disable-pip-version-check \
        "transformers>=4.51.3,<4.58" "tokenizers<0.22" "accelerate>=0.30,<0.40" \
        "sentencepiece" "protobuf" "numba>=0.60" "hf_transfer" "pillow" 2>&1 | tail -5
}
python -c "import torch, torch_neuronx, transformers, neuronx_distributed_inference; print(f'[CHK] torch={torch.__version__} tnx={torch_neuronx.__version__} transformers={transformers.__version__}')" || exit 1

FREE_GB=$(df /home --output=avail | tail -1 | awk '{print int($1/1024/1024)}')
echo "[DISK] free /home: ${FREE_GB} GB"
if [ "$FREE_GB" -lt 150 ]; then
    echo "[ERROR] need >= 150 GB for full 64-layer, have ${FREE_GB} GB"
    exit 9
fi

TS=$(date -u +%Y%m%dT%H%M%S)
export NEURON_COMPILE_CACHE_URL=/home/ubuntu/neuron-cache-stockmark-${NUM_LAYERS}l-${TS}
mkdir -p "$NEURON_COMPILE_CACHE_URL"
rm -rf /tmp/nxd_model

python "$EXP_DIR/code/compile_and_test.py" 2>&1 | tee "$EXP_DIR/results/run-${NUM_LAYERS}l.out"
RC=$?

echo "=== SUMMARY ==="
cat "$EXP_DIR/results/metrics-${NUM_LAYERS}l.json" 2>/dev/null
echo "=== Job end: $(date -u +%FT%TZ) RC=$RC ==="
exit $RC
