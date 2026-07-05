#!/bin/bash
set -u
source /opt/pytorch/bin/activate
export HF_HUB_DISABLE_PROGRESS_BARS=1 VLLM_LOGGING_LEVEL=WARNING
GPU=$1; TAG=$2; REPO=$3; shift 3; EXTRA="$@"
PORT=$((8010 + GPU))
LOG=~/translate2_${TAG}.log; : > "$LOG"
CUDA_VISIBLE_DEVICES=$GPU nohup vllm serve "$REPO" --port $PORT --max-model-len 4096 --gpu-memory-utilization 0.90 $EXTRA >> "$LOG" 2>&1 &
SERVE_PID=$!
for i in $(seq 1 90); do
  if curl -s -m 3 http://localhost:$PORT/v1/models >/dev/null 2>&1; then echo "server up ($i)" >> "$LOG"; break; fi
  sleep 5
done
python3 ~/translate_eval2.py "$REPO" "$TAG" $PORT >> ~/translate_results2.jsonl 2>> "$LOG"
kill $SERVE_PID 2>/dev/null; sleep 5
echo "=== done $TAG ===" >> "$LOG"
