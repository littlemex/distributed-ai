#!/usr/bin/env bash
# Gemma 3 27B fp8 + multi-LoRA を 1 GPU (TP=1) で起動する (Approach B, big model)。
# 8 replica 構成では本スクリプトを GPU 0..7 / port 8000..8007 で 8 個起動する (§3)。
#
# F2 (実験最大の実装リスク): 1スケジューラバッチ内 distinct adapter 数 > --max-loras で
#   即 RuntimeError。1000 テナント高同時実行ほどバッチ内 distinct 数が増えるので
#   --max-loras は「バッチ内同時 distinct ピーク」以上に取る (まず 32、足りなければ 64)。
# F3: --max-cpu-loras 1000 で全 adapter を CPU 常駐 → swap-in を disk read でなく
#   H2D copy のみに限定 (~3-7ms)。
# sm_103/CUDA13: Triton punica kernel はアーキガード無し。image が main build なら
#   VLLM_LORA_ENABLE_DUAL_STREAM=1 を試す価値あり (v0.9.1 には無い)。
#
# 使い方:
#   CUDA_VISIBLE_DEVICES=0 PORT=8000 ./serve_vllm_27b.sh
set -euo pipefail

PORT="${PORT:-8000}"
MAX_LORAS="${MAX_LORAS:-32}"
MAX_CPU_LORAS="${MAX_CPU_LORAS:-1000}"

export VLLM_ALLOW_RUNTIME_LORA_UPDATING=true

vllm serve google/gemma-3-27b-it \
  --tensor-parallel-size 1 \
  --quantization fp8 \
  --enable-lora \
  --max-loras "${MAX_LORAS}" \
  --max-lora-rank 16 \
  --lora-dtype bfloat16 \
  --max-cpu-loras "${MAX_CPU_LORAS}" \
  --gpu-memory-utilization 0.92 \
  --max-model-len 8192 \
  --max-num-seqs 256 \
  --port "${PORT}"
