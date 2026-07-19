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

# Build the train.py flags as a bash ARRAY (not a single string). Each element
# is one argv token, so values are never re-split by a shell. The array is
# expanded into the `ray job submit -- ...` argv below; MODEL_ARGS itself is
# expanded inside recipe/launcher/grpo_launch.sh, in the same shell that sources
# the SLIME model script. See that launcher for why this avoids the shell
# escaping trap that a `-- bash -c "...${MODEL_ARGS[@]}..."` string would hit.
#
# When RM_TYPE=remote_rm, point SLIME at the CPU-hosted reward Service via
# --rm-url (see kubernetes/reward-service.yaml). Otherwise scoring is in-process.
RM_ARGS=(--rm-type "${RM_TYPE}")
if [ "${RM_TYPE}" = "remote_rm" ]; then
    if [ -z "${RM_URL}" ]; then
        echo "[ERROR] RM_TYPE=remote_rm but RM_URL is not set. Configure it in env_vars."
        exit 1
    fi
    RM_ARGS+=(--rm-url "${RM_URL}")
    echo "  Reward:         remote_rm @ ${RM_URL}"
fi

# Optional extra train.py flags, injected without editing this recipe. Set the
# EXTRA_TRAIN_ARGS env var to a whitespace-separated list of flags in env_vars
# (or on the command line) and they are appended verbatim to the train.py argv.
# This is the supported extension point for experiments that need flags the
# baseline recipe does not set — e.g. observability (--use-tensorboard) or the
# training-inference mismatch study (--get-mismatch-metrics --custom-config-path
# examples/train_infer_mismatch_helper/mis.py:compute_mis_weights_with_cp,
# --use-tis, --use-rollout-logprobs) or LR scheduling (--lr-decay-style ...).
# Word-splitting here is intentional so a single env var can carry several flags;
# values containing spaces are not supported (none of the intended flags need
# them). The array keeps each token separate across the Ray job boundary, the
# same shell-safety property the rest of this recipe relies on.
EXTRA_TRAIN_ARGS_ARR=()
if [ -n "${EXTRA_TRAIN_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    EXTRA_TRAIN_ARGS_ARR=(${EXTRA_TRAIN_ARGS})
    echo "  Extra args:     ${EXTRA_TRAIN_ARGS}"
fi

# Dynamic batch is on by default (the baseline behaviour). It can be turned OFF
# with USE_DYNAMIC_BATCH=false purely for a diagnostic run: --use-dynamic-batch-size
# is a store_true flag, so EXTRA_TRAIN_ARGS cannot un-set it — this toggle is the
# only way to render an argv WITHOUT it. When unset/true, DYNAMIC_BATCH_ARGS below
# reproduces the exact tokens the baseline used (bit-identical argv). The only
# intended use is the ppo_kl artefact diagnosis (does the spurious ppo_kl vanish
# when micro-batch boundaries stop shifting between the old-logprob forward and
# the loss forward?). It MUST stay at the default for every result-bearing run.
DYNAMIC_BATCH_ARGS=(--use-dynamic-batch-size --max-tokens-per-gpu "${MAX_TOKENS_PER_GPU}")
if [ "${USE_DYNAMIC_BATCH:-true}" = "false" ]; then
    DYNAMIC_BATCH_ARGS=(--micro-batch-size "${MICRO_BATCH_SIZE:-1}")
    echo "  Dynamic batch:  OFF (diagnostic) micro-batch-size=${MICRO_BATCH_SIZE:-1}"
fi

TRAIN_ARGS=(
    --hf-checkpoint "${MODEL_LOCAL}"
    --ref-load "${MODEL_DIST}"
    --load "${CHECKPOINT_DIR}/qwen3-4b-grpo/"
    --save "${CHECKPOINT_DIR}/qwen3-4b-grpo/"
    --save-interval "${SAVE_INTERVAL}"

    --prompt-data "${PROMPT_DATA}"
    --input-key prompt
    --label-key label
    --apply-chat-template
    --rollout-shuffle

    "${RM_ARGS[@]}"

    --num-rollout "${NUM_ROLLOUT}"
    --rollout-batch-size "${ROLLOUT_BATCH_SIZE}"
    --n-samples-per-prompt "${N_SAMPLES_PER_PROMPT}"
    --num-steps-per-rollout "${NUM_STEPS_PER_ROLLOUT:-1}"
    --global-batch-size "${GLOBAL_BATCH_SIZE}"

    --rollout-max-response-len "${ROLLOUT_MAX_RESPONSE_LEN}"
    --rollout-temperature "${ROLLOUT_TEMPERATURE}"
    --balance-data

    --eval-interval 10
    --eval-prompt-data aime "${EVAL_DATA}"
    --n-samples-per-eval-prompt 8
    --eval-max-response-len 16384
    --eval-top-p 1

    --tensor-model-parallel-size "${TP_SIZE}"
    --pipeline-model-parallel-size "${PP_SIZE}"
    --context-parallel-size "${CP_SIZE}"
    --expert-model-parallel-size "${EP_SIZE}"
    --sequence-parallel

    --recompute-granularity full
    --recompute-method uniform
    --recompute-num-layers 1

    "${DYNAMIC_BATCH_ARGS[@]}"

    --advantage-estimator grpo
    --use-kl-loss
    --kl-loss-coef 0.00
    --kl-loss-type low_var_kl
    --entropy-coef 0.00
    --eps-clip 0.2
    --eps-clip-high 0.28

    --optimizer adam
    --lr "${LEARNING_RATE}"
    --lr-decay-style constant
    --weight-decay 0.1
    --adam-beta1 0.9
    --adam-beta2 0.98

    --actor-num-nodes "${ACTOR_NUM_NODES}"
    --actor-num-gpus-per-node "${ACTOR_GPUS_PER_NODE}"
    --colocate
    --rollout-num-gpus-per-engine "${ROLLOUT_GPUS_PER_ENGINE}"

    --sglang-mem-fraction-static 0.8
    # SGLang forwards this to uvicorn's log_level, whose LOG_LEVELS dict is keyed
    # by lowercase names only (critical/error/warning/info/debug/trace) with no
    # "warn" key. Uppercase "WARN" (the original value) raises a KeyError and
    # uvicorn dies before the rollout HTTP server binds, so the rollout health
    # check never passes and training hangs before it starts. Use lowercase
    # "warning" to preserve the original intended verbosity.
    --sglang-log-level warning

    # Experiment-specific flags injected via the EXTRA_TRAIN_ARGS env var (empty
    # by default, so the baseline behaviour is unchanged). See the block above.
    "${EXTRA_TRAIN_ARGS_ARR[@]}"
)

# Submit via Ray job API.
#
# The entrypoint after `--` is `bash grpo_launch.sh <flags>` (plain argv tokens,
# no shell array crosses the ray boundary). --working-dir uploads the launcher
# to the Ray workers; the SLIME code itself is already in the image at
# /opt/slime. MODEL_SCRIPT is forwarded so the launcher can source the right
# model definition.
echo "[INFO] Submitting Ray job..."

ray job submit \
    --address="http://127.0.0.1:8265" \
    --working-dir "${SCRIPT_DIR}/launcher" \
    --runtime-env-json="{
        \"env_vars\": {
            \"PYTHONPATH\": \"/root/Megatron-LM:/root/miles\",
            \"HF_TOKEN\": \"${HF_TOKEN}\",
            \"MODEL_SCRIPT\": \"${MODEL_SCRIPT}\",
            \"TOKENIZERS_PARALLELISM\": \"false\",
            \"NCCL_DEBUG\": \"WARN\",
            \"FI_PROVIDER\": \"efa\",
            \"FI_EFA_USE_DEVICE_RDMA\": \"1\",
            \"TENSORBOARD_DIR\": \"${TENSORBOARD_DIR:-}\"
        }
    }" \
    -- bash grpo_launch.sh "${TRAIN_ARGS[@]}"

echo "[INFO] Job submitted. Monitor at http://localhost:8265"
