#!/bin/bash
#SBATCH --job-name=stockmark-docreasoner-compile
#SBATCH --partition=compute-trn2
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=2:00:00
#SBATCH --chdir=/home/ubuntu

# 1-layer smoke test compile + probe cos + 1-prompt generate for
# stockmark/Stockmark-DocReasoner-Qwen2.5-VL-32B on trn2.3xlarge.
#
# Required env vars (set via --export=ALL,VAR=... or in submitter shell):
#   HF_TOKEN    Hugging Face token (public model, avoids rate limits)
#   EXP_DIR     absolute path to this experiment directory
#   NUM_LAYERS  1 for smoke (fast, ~3 min) or 64 for full (~10 min)
#
# Output: metrics-${NUM_LAYERS}l.json under $EXP_DIR/results/

export PATH=/opt/neuron_venv/bin:/opt/aws/neuron/bin:$PATH

# HF xet (LFS successor) stalls at <1 MB/s from sa-east-1 (2026-05 observed);
# plain HTTPS with hf_transfer restores ~100 MB/s.
export HF_HUB_DISABLE_XET=1
export HF_HUB_ENABLE_HF_TRANSFER=1

# trn2.3xlarge = 4 Trainium2 chips, 8 physical NeuronCores at LNC=1.
export NEURON_LOGICAL_NC_CONFIG=1
export NEURON_RT_VISIBLE_CORES=0-7
export NEURON_RT_NUM_CORES=8

: "${HF_TOKEN:?set HF_TOKEN before sbatch submit}"
: "${EXP_DIR:?set EXP_DIR to the dir containing code/compile_and_test.py}"
: "${NUM_LAYERS:=1}"

export HF_TOKEN EXP_DIR NUM_LAYERS

mkdir -p "$EXP_DIR/results" "$EXP_DIR/traces"

echo "=== Job start: $(date -u +%FT%TZ) EXP_DIR=$EXP_DIR NUM_LAYERS=$NUM_LAYERS ==="
source /opt/neuron_venv/bin/activate

# Install NxD / NxDI from GitHub main (pip release may not contain Qwen2.5-VL).
python -c "import neuronx_distributed_inference" 2>/dev/null || {
    echo "[SETUP] torch_neuronx 2.9 upgrade + NxD/NxDI GitHub install"
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
    echo "[SETUP] installing transformers + deps"
    sudo /opt/neuron_venv/bin/pip install --quiet --disable-pip-version-check \
        "transformers>=4.51.3,<4.58" "tokenizers<0.22" "accelerate>=0.30,<0.40" \
        "sentencepiece" "protobuf" "numba>=0.60" "hf_transfer" "pillow" 2>&1 | tail -5
}
python -c "import torch, torch_neuronx, transformers, neuronx_distributed_inference; from transformers import Qwen2_5_VLForConditionalGeneration; print(f'[CHK] torch={torch.__version__} tnx={torch_neuronx.__version__} transformers={transformers.__version__}')" || exit 1

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
