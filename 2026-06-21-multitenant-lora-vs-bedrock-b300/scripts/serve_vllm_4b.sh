#!/usr/bin/env bash
# Gemma 3 4B fp8 + multi-LoRA を 1 GPU (TP=1) で起動する (Approach B, small model)。
# 4B は ~4GB と軽く KV cache 余裕大 → --max-loras を 64 と大きめに取れる (F2 リスク緩和)。
# 8 replica 構成では port 8001 系で 8 個起動。
#
# 使い方:
#   CUDA_VISIBLE_DEVICES=0 PORT=8001 ./serve_vllm_4b.sh
set -euo pipefail

PORT="${PORT:-8001}"
MAX_LORAS="${MAX_LORAS:-64}"
MAX_CPU_LORAS="${MAX_CPU_LORAS:-1000}"

export VLLM_ALLOW_RUNTIME_LORA_UPDATING=true

vllm serve google/gemma-3-4b-it \
  --tensor-parallel-size 1 \
  --quantization fp8 \
  --enable-lora \
  --max-loras "${MAX_LORAS}" \
  --max-lora-rank 16 \
  --lora-dtype bfloat16 \
  --max-cpu-loras "${MAX_CPU_LORAS}" \
  --gpu-memory-utilization 0.90 \
  --max-model-len 8192 \
  --port "${PORT}"
