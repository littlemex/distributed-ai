#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# ============================================================
# SLIME GRPO Training — Qwen3-4B on HyperPod EKS (Colocated)
#
# This script submits a Ray job to run GRPO training using SLIME
# with Megatron-LM training and SGLang inference on shared GPUs.
#
# Prerequisites:
#   - Ray cluster deployed via kubernetes/raycluster.yaml
#   - Model downloaded and converted to torch_dist format
#   - Training data on FSx
#   - source env_vars before running
#
# Usage:
#   source env_vars
#   bash recipe/run_grpo_qwen3_4b.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

# Source environment if not already loaded. Override the file with ENV_FILE,
# e.g.  ENV_FILE=env_vars.disaggregated bash recipe/run_grpo_qwen3_4b.sh
if [[ -z "${MODEL_LOCAL:-}" ]]; then
    ENV_FILE="${ENV_FILE:-${PROJECT_DIR}/env_vars}"
    echo "[INFO] Sourcing ${ENV_FILE}..."
    source "${ENV_FILE}"
fi

# Validate required variables
for var in MODEL_LOCAL MODEL_DIST PROMPT_DATA CHECKPOINT_DIR; do
    if [[ -z "${!var:-}" ]]; then
        echo "[ERROR] ${var} is not set. Please configure env_vars."
        exit 1
    fi
done

echo "============================================================"
echo "  SLIME GRPO Training — Qwen3-4B (Colocated Mode)"
echo "============================================================"
echo "  Model:          ${MODEL_LOCAL}"
echo "  Megatron ckpt:  ${MODEL_DIST}"
echo "  Training data:  ${PROMPT_DATA}"
echo "  Checkpoints:    ${CHECKPOINT_DIR}/qwen3-4b-grpo/"
echo "  Nodes:          ${ACTOR_NUM_NODES} x ${ACTOR_GPUS_PER_NODE} GPUs"
echo "  Colocated:      ${COLOCATE}"
echo "  Rollout BS:     ${ROLLOUT_BATCH_SIZE} x ${N_SAMPLES_PER_PROMPT}"
echo "  Global BS:      ${GLOBAL_BATCH_SIZE}"
echo "  Num rollouts:   ${NUM_ROLLOUT}"
echo "============================================================"

# Build the training command
# When RM_TYPE=remote_rm, point SLIME at the CPU-hosted reward Service via
# --rm-url (see kubernetes/reward-service.yaml). Otherwise scoring is in-process.
RM_ARGS="--rm-type ${RM_TYPE}"
if [ "${RM_TYPE}" = "remote_rm" ]; then
    if [ -z "${RM_URL}" ]; then
        echo "[ERROR] RM_TYPE=remote_rm but RM_URL is not set. Configure it in env_vars."
        exit 1
    fi
    RM_ARGS="${RM_ARGS} --rm-url ${RM_URL}"
    echo "  Reward:         remote_rm @ ${RM_URL}"
fi

# --- リファレンスからの唯一の必要差分: MODEL_ARGS の literal 展開 ---
# リファレンス recipe は TRAIN_CMD 内で `\${MODEL_ARGS[@]}` をエスケープし、
# worker が単一 bash -c で受けて展開する HyperPod 前提。RayCluster 経由では
# `ray job submit -- bash -c "..."` で shell が一段深くネストし、bash 配列
# `${MODEL_ARGS[@]}` が中間 sh 層で空展開される (実証: ネスト時 0 要素)。
# head 側で `${MODEL_ARGS[*]}` を literal 文字列に展開してから渡せば回避できる。
# コードは image 内 (/opt/slime, /opt/Megatron-LM) を使う — FSx pyenv は注入しない
# (前回の plain-image 方式の名残であり NGC image の TE 2.12 を shadow するため)。
# --- colocated / disaggregated 切替え (COLOCATE で分岐、リファレンス2スクリプトを統合) ---
# colocated:     --colocate (train と rollout が同一 GPU、weight sync は CUDA IPC)
# disaggregated: --rollout-num-gpus N (train と rollout が別 GPU、weight sync は NCCL/EFA)
# これ1点で UpdateWeightFromTensor / UpdateWeightFromDistributed が切り替わる (actor.py:135)。
if [ "${COLOCATE}" = "true" ]; then
    COLOCATE_ARGS="--colocate"
else
    COLOCATE_ARGS="--rollout-num-gpus ${ROLLOUT_NUM_GPUS}"
fi

source /opt/slime/scripts/models/${MODEL_SCRIPT}
MODEL_ARGS_LITERAL="${MODEL_ARGS[*]}"
TRAIN_CMD="cd /opt/slime && python3 train.py \
    ${MODEL_ARGS_LITERAL} \
    --hf-checkpoint ${MODEL_LOCAL} \
    --ref-load ${MODEL_DIST} \
    --load ${CHECKPOINT_DIR}/${CKPT_SUBDIR:-qwen3-4b-grpo}/ \
    --save ${CHECKPOINT_DIR}/${CKPT_SUBDIR:-qwen3-4b-grpo}/ \
    --save-interval ${SAVE_INTERVAL} \
    \
    --prompt-data ${PROMPT_DATA} \
    --input-key prompt \
    --label-key label \
    --apply-chat-template \
    --rollout-shuffle \
    \
    ${RM_ARGS} \
    \
    --num-rollout ${NUM_ROLLOUT} \
    --rollout-batch-size ${ROLLOUT_BATCH_SIZE} \
    --n-samples-per-prompt ${N_SAMPLES_PER_PROMPT} \
    --num-steps-per-rollout ${NUM_STEPS_PER_ROLLOUT:-1} \
    --global-batch-size ${GLOBAL_BATCH_SIZE} \
    \
    --rollout-max-response-len ${ROLLOUT_MAX_RESPONSE_LEN} \
    --rollout-temperature ${ROLLOUT_TEMPERATURE} \
    --balance-data \
    \
    --eval-interval 10 \
    --eval-prompt-data aime ${EVAL_DATA} \
    --n-samples-per-eval-prompt 8 \
    --eval-max-response-len 16384 \
    --eval-top-p 1 \
    \
    --tensor-model-parallel-size ${TP_SIZE} \
    --pipeline-model-parallel-size ${PP_SIZE} \
    --context-parallel-size ${CP_SIZE} \
    --expert-model-parallel-size ${EP_SIZE} \
    ${MOE_ARGS:-} \
    --sequence-parallel \
    \
    --recompute-granularity full \
    --recompute-method uniform \
    --recompute-num-layers 1 \
    \
    --use-dynamic-batch-size \
    --max-tokens-per-gpu ${MAX_TOKENS_PER_GPU} \
    \
    --advantage-estimator grpo \
    --use-kl-loss \
    --kl-loss-coef 0.00 \
    --kl-loss-type low_var_kl \
    --entropy-coef 0.00 \
    --eps-clip 0.2 \
    --eps-clip-high 0.28 \
    \
    --optimizer adam \
    --lr ${LEARNING_RATE} \
    --lr-decay-style constant \
    --weight-decay 0.1 \
    --adam-beta1 0.9 \
    --adam-beta2 0.98 \
    \
    --actor-num-nodes ${ACTOR_NUM_NODES} \
    --actor-num-gpus-per-node ${ACTOR_GPUS_PER_NODE} \
    ${COLOCATE_ARGS} ${TRAIN_EXTRA_ARGS:-} \
    --rollout-num-gpus-per-engine ${ROLLOUT_GPUS_PER_ENGINE} \
    \
    --sglang-mem-fraction-static ${SGLANG_MEM_FRACTION:-0.8} \
    --sglang-log-level ${SGLANG_LOG_LEVEL:-WARN} ${SGLANG_EXTRA_ARGS:-}"
# ${TRAIN_EXTRA_ARGS}: train(Megatron) 側の B300 固有 delta を env_vars に隔離するフック。
# 例: --no-offload-train --no-offload-rollout。offload_train が有効だと SLIME が
# torch_memory_saver の cu12 版 .so を LD_PRELOAD し (actor_group.py:72)、NGC(cu13)image で
# `libcudart.so.12: not found` により train worker の bash が即死 → ActorUnschedulableError。
# B300 192GB なら offload 不要なので切る (設計判断としても妥当)。
# ${SGLANG_EXTRA_ARGS}: B300 (sm_103) 固有 delta を env_vars に隔離するフック。
# リファレンスの env 駆動思想に合わせ、recipe 本体はリファレンス形のまま保つ。
# 例: B300 の 192GB HBM では SGLang が cuda_graph_max_bs を巨大に自動設定し、
# colocated 16 engine/node で capture が CPU 競合し HTTP server 起動前に timeout する。
# --sglang-cuda-graph-max-bs で capture 範囲を絞って回避。TE/Megatron とは無関係。

# Submit via Ray job API
echo "[INFO] Submitting Ray job..."

# ${ENTRYPOINT_GPUS}: MoE モデル (--moe-grouped-gemm) は Megatron の validate_args が
# torch.cuda.get_device_capability() を呼ぶ (arguments.py:906)。train.py の parse_args は
# ray job の driver (head pod, GPU 0) で実行されるため、GPU 0 だと "Found no NVIDIA driver"。
# driver を GPU ノードに載せて回避する。dense モデルは 0 でよい (validate が GPU 不要)。
ray job submit \
    --address="http://127.0.0.1:8265" \
    --entrypoint-num-gpus ${ENTRYPOINT_GPUS:-0} \
    --runtime-env-json="{
        \"env_vars\": {
            \"PYTHONPATH\": \"/opt/Megatron-LM\",
            \"HF_TOKEN\": \"${HF_TOKEN}\",
            \"TOKENIZERS_PARALLELISM\": \"false\",
            \"NCCL_DEBUG\": \"WARN\",
            \"FI_PROVIDER\": \"efa\",
            \"FI_EFA_USE_DEVICE_RDMA\": \"1\",
            \"PYTORCH_CUDA_ALLOC_CONF\": \"${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}\"
        }
    }" \
    -- bash -c "${TRAIN_CMD}"

echo "[INFO] Job submitted. Monitor at http://localhost:8265"
