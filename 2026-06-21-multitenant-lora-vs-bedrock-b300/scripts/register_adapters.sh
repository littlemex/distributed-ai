#!/usr/bin/env bash
# 起動済み vLLM に N 個の LoRA adapter を runtime API (/v1/load_lora_adapter) で登録する。
# --lora-modules で 1000 個を起動時に渡すと逐次 disk read で ~35-70 秒ブロックするため、
# 起動後にバックグラウンドで並列 POST する方式 (§5)。
# 前提: vLLM を VLLM_ALLOW_RUNTIME_LORA_UPDATING=true で起動していること。
#
# 使い方:
#   ./register_adapters.sh /adapters/gemma3-27b 1000 8000
set -euo pipefail

BASE_DIR="${1:?usage: register_adapters.sh <adapter_base_dir> <n> [port]}"
N="${2:?usage: register_adapters.sh <adapter_base_dir> <n> [port]}"
PORT="${3:-8000}"

echo "[INFO] registering ${N} adapters from ${BASE_DIR} to port ${PORT}"
for i in $(seq 0 $((N - 1))); do
  curl -s -X POST "http://localhost:${PORT}/v1/load_lora_adapter" \
    -H 'Content-Type: application/json' \
    -d "{\"lora_name\": \"adapter-${i}\", \"lora_path\": \"${BASE_DIR}/adapter-${i}\"}" \
    > /dev/null &
  # 50 並列でスロットリング
  [ $((i % 50)) -eq 0 ] && wait
done
wait
echo "[OK] All ${N} adapters registered on port ${PORT}"
