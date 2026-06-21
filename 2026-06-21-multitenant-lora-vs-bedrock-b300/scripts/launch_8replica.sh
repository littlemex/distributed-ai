#!/usr/bin/env bash
# pod 内で 8x TP=1 Gemma 4 31B fp8 レプリカ (port 8000-8007) を起動する。
# DESIGN-v2-topology.md §5 の確定フラグ。各 replica は CUDA_VISIBLE_DEVICES=0..7 で 1 GPU 専有。
# ログは /mnt/k8s-disks/0/vllm-r{0..7}.log。
#
# 使い方 (pod 内):
#   bash /tmp/launch_8replica.sh
#   # 全 replica の health 200 を待ってから register_adapters.sh -> concurrency_sweep.py
set -uo pipefail

MODEL=${MODEL:-google/gemma-4-31B-it}
LOGDIR=/mnt/k8s-disks/0
N=${N:-8}

# [重要] GLOO_SOCKET_IFNAME=eth0 (manifest env) は hostNetwork ノードで存在しない
# (実 IF は enp71s0 等)。gloo が "Unable to find address for: eth0" でクラッシュする。
# TP=1 なので gloo の auto-detect で十分。明示的に unset する。
unset GLOO_SOCKET_IFNAME

for i in $(seq 0 $((N-1))); do
  PORT=$((8000 + i))
  echo "[INFO] launching replica $i on GPU $i, port $PORT"
  CUDA_VISIBLE_DEVICES=$i nohup vllm serve "$MODEL" \
    --tensor-parallel-size 1 \
    --quantization fp8 \
    --kv-cache-dtype fp8_e4m3 \
    --enable-lora \
    --max-loras 32 \
    --max-lora-rank 16 \
    --lora-dtype bfloat16 \
    --max-cpu-loras 1000 \
    --gpu-memory-utilization 0.95 \
    --max-model-len 4096 \
    --max-num-seqs 1024 \
    --max-num-batched-tokens 16384 \
    --port "$PORT" \
    > "$LOGDIR/vllm-r$i.log" 2>&1 &
done

echo "[INFO] all $N replicas launching. waiting for health..."
for i in $(seq 0 $((N-1))); do
  PORT=$((8000 + i))
  for t in $(seq 1 120); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/health" 2>/dev/null)
    if [ "$code" = "200" ]; then echo "  replica $i (port $PORT): READY"; break; fi
    [ "$t" = "120" ] && echo "  replica $i (port $PORT): TIMEOUT (check $LOGDIR/vllm-r$i.log)"
    sleep 5
  done
done
echo "[OK] launch sequence complete"
