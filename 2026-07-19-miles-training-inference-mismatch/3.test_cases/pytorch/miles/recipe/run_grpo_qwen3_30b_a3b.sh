#!/usr/bin/env bash
# STATUS: RUNS on 2 nodes / 16 GPU H200 (--colocate + --use-distributed-optimizer + triton
#   MoE runner), but does NOT produce usable training. Across 4 runs generation falls into a
#   repetition loop and raw_reward stays 0.0; the mis_kl those runs report is measuring
#   repetition, not train/rollout mismatch, and is marked UNUSABLE in the data ledger. Root
#   cause unresolved -- see docs/RESULTS.md and experiment/h200_results/P2R_30B_INVALID.md.
#   (An earlier header quoted "mis_kl 0.00192" as verified; no run produced that value and it
#   has been retracted.) The disaggregated actor-8 layout (see the parent slime recipe) needs
#   B300 288GB and is UNVERIFIED on H200; colocated 16-GPU with the distributed optimizer is
#   the H200-fitting path and is the one shipped as default here.
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# ============================================================
# miles GRPO Training — Qwen3-30B-A3B MoE on HyperPod EKS
# (Colocated Mode: training and rollout time-share the same 16 GPUs)
#
# This configuration runs the 30B MoE model with:
#   - actor 2 nodes x 8 GPUs = 16 GPU, TP=2 PP=1 CP=1 EP=2
#   - --use-distributed-optimizer shards the 30B optimizer state across the 16 GPU
#     so the static memory fits H200 (141GB); without it the actor OOMs.
#   - rollout time-shares the same 16 GPU (COLOCATE=true), 2 GPU per SGLang engine.
#
# Prerequisites:
#   - Ray cluster deployed via kubernetes/raycluster.yaml (2 workers for 16 GPU)
#   - Model downloaded and converted to torch_dist format
#   - Training data on FSx
#   - source env_vars with the "ALTERNATE: Qwen3-30B-A3B MoE" block in
#     env_vars.colocated.example uncommented
#
# Usage:
#   source env_vars  # with the 30B MoE block (env_vars.colocated.example) active
#   bash recipe/run_grpo_qwen3_30b_a3b.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

# Source environment if not already loaded. Override the file with ENV_FILE,
# e.g.  ENV_FILE=env_vars.disaggregated bash recipe/run_grpo_qwen3_30b_a3b.sh
if [[ -z "${MODEL_LOCAL:-}" ]]; then
    ENV_FILE="${ENV_FILE:-${PROJECT_DIR}/env_vars}"
    echo "[INFO] Sourcing ${ENV_FILE}..."
    source "${ENV_FILE}"
fi

# Validate required variables (same guard as the 4B recipe; without it a missing
# var trips `set -u` with an opaque error deep in the argv build).
for var in MODEL_LOCAL MODEL_DIST PROMPT_DATA CHECKPOINT_DIR MODEL_SCRIPT RM_TYPE \
           COLOCATE TP_SIZE PP_SIZE CP_SIZE EP_SIZE ACTOR_NUM_NODES ACTOR_GPUS_PER_NODE \
           ROLLOUT_NUM_GPUS ROLLOUT_GPUS_PER_ENGINE NUM_ROLLOUT ROLLOUT_BATCH_SIZE \
           N_SAMPLES_PER_PROMPT GLOBAL_BATCH_SIZE MAX_TOKENS_PER_GPU \
           ROLLOUT_MAX_RESPONSE_LEN ROLLOUT_TEMPERATURE LEARNING_RATE SAVE_INTERVAL; do
    if [[ -z "${!var:-}" ]]; then
        echo "[ERROR] ${var} is not set. Please configure env_vars."
        exit 1
    fi
done

# Validate this is the MoE configuration. The verified path is colocated on 16 GPU;
# disaggregated (COLOCATE=false) is only viable on B300-class HBM and is UNVERIFIED here.
# This recipe passes --colocate unconditionally below, so COLOCATE=false cannot be honoured.
# Warning and continuing would run the colocated layout while the env said otherwise; refuse.
if [[ "${COLOCATE:-true}" != "true" ]]; then
    echo "[ERROR] COLOCATE=${COLOCATE} but this recipe only builds the colocated layout." >&2
    echo "[ERROR] Disaggregated 30B needs B300 288GB HBM and is UNVERIFIED on H200; the path" >&2
    echo "[ERROR] measured here is COLOCATE=true (actor 2x8 + --use-distributed-optimizer)." >&2
    exit 1
fi

echo "============================================================"
echo "  miles GRPO Training — Qwen3-30B-A3B MoE (Colocated, 16 GPU)"
echo "============================================================"
echo "  Model:             ${MODEL_LOCAL}"
echo "  Megatron ckpt:     ${MODEL_DIST}"
echo "  Training data:     ${PROMPT_DATA}"
echo "  Checkpoints:       ${CHECKPOINT_DIR}/qwen3-30b-a3b-grpo/"
echo "  Actor:             ${ACTOR_NUM_NODES} nodes x ${ACTOR_GPUS_PER_NODE} GPUs"
echo "  Rollout GPUs:      ${ROLLOUT_NUM_GPUS} (${ROLLOUT_GPUS_PER_ENGINE} per engine)"
echo "  Parallelism:       TP=${TP_SIZE} PP=${PP_SIZE} CP=${CP_SIZE} EP=${EP_SIZE}"
echo "  Rollout BS:        ${ROLLOUT_BATCH_SIZE} x ${N_SAMPLES_PER_PROMPT}"
echo "  Global BS:         ${GLOBAL_BATCH_SIZE}"
echo "============================================================"

# Build the train.py flags as a bash ARRAY (not a single string). Each element
# is one argv token, so values are never re-split by a shell. The array is
# expanded into the `ray job submit -- ...` argv below; MODEL_ARGS itself is
# expanded inside recipe/launcher/grpo_launch.sh, in the same shell that sources
# the miles model script. See that launcher for why this avoids the shell
# escaping trap that a `-- bash -c "...${MODEL_ARGS[@]}..."` string would hit.
#
# When RM_TYPE=remote_rm, point miles at the CPU-hosted reward Service via
# --rm-url (see kubernetes/reward-service.yaml). Otherwise scoring is in-process.
RM_ARGS=(--rm-type "${RM_TYPE}")
if [ "${RM_TYPE}" = "remote_rm" ]; then
    if [ -z "${RM_URL:-}" ]; then
        echo "[ERROR] RM_TYPE=remote_rm but RM_URL is not set. Configure it in env_vars."
        exit 1
    fi
    RM_ARGS+=(--rm-url "${RM_URL}")
    echo "  Reward:         remote_rm @ ${RM_URL}"
fi

TRAIN_ARGS=(
    --hf-checkpoint "${MODEL_LOCAL}"
    --ref-load "${MODEL_DIST}"
    --load "${CHECKPOINT_DIR}/qwen3-30b-a3b-grpo/"
    --save "${CHECKPOINT_DIR}/qwen3-30b-a3b-grpo/"
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
    --n-samples-per-eval-prompt 4
    --eval-max-response-len 16384
    --eval-top-p 1

    --tensor-model-parallel-size "${TP_SIZE}"
    --pipeline-model-parallel-size "${PP_SIZE}"
    --context-parallel-size "${CP_SIZE}"
    --expert-model-parallel-size "${EP_SIZE}"
    --expert-tensor-parallel-size 1
    --sequence-parallel

    --recompute-granularity full
    --recompute-method uniform
    --recompute-num-layers 1

    --use-dynamic-batch-size
    --max-tokens-per-gpu "${MAX_TOKENS_PER_GPU}"

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
    # Colocated on 16 GPU: actor and rollout time-share the same GPUs. Required
    # for 30B on H200 -- with all 16 GPU behind the actor, --use-distributed-optimizer
    # shards the 30B optimizer state so static memory fits 141GB. Confining the
    # actor to 8 GPU (a single node) OOMs (30B static ~121GB/GPU on 8-way).
    --colocate
    --use-distributed-optimizer
    --rollout-num-gpus "${ROLLOUT_NUM_GPUS}"
    --rollout-num-gpus-per-engine "${ROLLOUT_GPUS_PER_ENGINE}"

    # Verified value on H200 colocated. 0.85 (the original hardcode) leaves too
    # little room once the actor and rollout share the same GPUs; 0.75 completed.
    --sglang-mem-fraction-static "${SGLANG_MEM_FRACTION:-0.75}"
    # MoE online weight update on SGLang 0.5.12+ requires the triton runner: the
    # default flashinfer MoE runner is incompatible with SLIME/miles's in-place
    # weight update, so the engine must serve with --sglang-moe-runner-backend
    # triton and expert parallelism must be declared to SGLang explicitly.
    --sglang-moe-runner-backend triton
    --sglang-expert-parallel-size "${EP_SIZE}"
    # SGLang forwards this to uvicorn's log_level, whose LOG_LEVELS dict is keyed
    # by lowercase names only (critical/error/warning/info/debug/trace) with no
    # "warn" key. Uppercase "WARN" (the original value) raises a KeyError and
    # uvicorn dies before the rollout HTTP server binds, so the rollout health
    # check never passes and training hangs before it starts. Use lowercase
    # "warning" to preserve the original intended verbosity.
    --sglang-log-level warning
    # NOTE: the original recipe passed `--sglang-enable-ep-moe`, which SGLang
    # 0.5.12 removed. SLIME v0.2.4 registers --sglang-* flags from SGLang's live
    # ServerArgs (parse_known_args / ignore_unknown_args), so the dead flag is
    # silently ignored rather than erroring -- it is dropped here in favour of the
    # explicit --sglang-moe-runner-backend / --sglang-expert-parallel-size above.
)

# Experiment-specific flags injected via EXTRA_TRAIN_ARGS, same mechanism as the
# 4B recipe. The mismatch study passes the measurement + dropout + seed flags here
# (identical to the slime test case) so the two frameworks compare apple-to-apple:
#   EXTRA_TRAIN_ARGS="--use-tensorboard --get-mismatch-metrics \
#     --custom-tis-function-path examples.train_infer_mismatch_helper.mis.compute_mis_weights_with_cp \
#     --custom-config-path /fsx/configs/mis_metrics_only.yaml \
#     --seed 1234 --rollout-seed 42 --attention-dropout 0 --hidden-dropout 0"
# NOTE: --custom-tis-function-path must be a DOTTED module path, not "file.py:func"
# -- load_function does rpartition('.') + import_module, so the slash form fails
# with ModuleNotFoundError at the loss forward (late, after rollout). The module
# is on PYTHONPATH (/root/miles) below.
EXTRA_TRAIN_ARGS_ARR=()
if [ -n "${EXTRA_TRAIN_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    EXTRA_TRAIN_ARGS_ARR=(${EXTRA_TRAIN_ARGS})
    echo "  Extra args:     ${EXTRA_TRAIN_ARGS}"
fi
# ${arr[@]+...} guards the empty-array + `set -u` case on bash < 4.4 (macOS 3.2).
TRAIN_ARGS+=(${EXTRA_TRAIN_ARGS_ARR[@]+"${EXTRA_TRAIN_ARGS_ARR[@]}"})

# Submit via Ray job API.
#
# The entrypoint after `--` is `bash grpo_launch.sh <flags>` (plain argv tokens,
# no shell array crosses the ray boundary). --working-dir uploads the launcher
# to the Ray workers; the miles code itself is already in the image at
# /root/miles (on PYTHONPATH below). MODEL_SCRIPT is forwarded so the launcher
# can source the right model definition.
#
# --entrypoint-resources '{"gpu_node": 0.001}' pins the driver to a GPU worker
# (miles imports mooncake / libcuda at module load; the head is a non-GPU pod).
# CUDA_DEVICE_MAX_CONNECTIONS=1 is required by Megatron for TP>1 (30B is TP=2).
# HF_TOKEN is NOT set here: it is injected into the pod env from the k8s Secret in
# raycluster.yaml, so it never lands in the Ray GCS runtime-env.
echo "[INFO] Submitting Ray job for MoE GRPO training..."

ray job submit \
    --address="http://127.0.0.1:8265" \
    --entrypoint-resources '{"gpu_node": 0.001}' \
    --working-dir "${SCRIPT_DIR}/launcher" \
    --runtime-env-json="{
        \"env_vars\": {
            \"PYTHONPATH\": \"/root/Megatron-LM:/root/miles\",
            \"CUDA_DEVICE_MAX_CONNECTIONS\": \"1\",
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
