#!/bin/bash
# Start one SGLang server on one GPU, measure it, and stop it.
#   serve_and_bench.sh <label> <model> <revision> <concurrency list> -- <extra launch_server flags...>
# Measures, in order:
#   1. bench_serving on random prompts (input 256, output 512 tokens) at each concurrency in the list
#   2. few_shot_gsm8k on 200 questions (5-shot, greedy), parallelism = the largest concurrency
# Outputs go to $OUT/<label>/. Needs VENV, OUT and GPU (the device index to use).
set -euo pipefail
LABEL=$1; MODEL=$2; REV=$3; CONC=$4; shift 4; [ "${1:-}" = "--" ] && shift
D=$OUT/$LABEL; mkdir -p "$D"
# FlashInfer compiles kernels at first use: it needs ninja (from the venv) and the CUDA toolkit that
# matches the CUDA build of torch in the venv.
export PATH=$VENV/bin:$PATH
TCU=$("$VENV/bin/python" -c 'import torch; print(torch.version.cuda)')
[ -d "/usr/local/cuda-$TCU" ] && export CUDA_HOME=/usr/local/cuda-$TCU PATH=/usr/local/cuda-$TCU/bin:$PATH
echo "torch cuda $TCU, CUDA_HOME ${CUDA_HOME:-unset}" > "$D/toolchain.txt"
PORT=$((30000 + ${GPU:-0}))
CUDA_VISIBLE_DEVICES=${GPU:-0} "$VENV/bin/python" -m sglang.launch_server --model-path "$MODEL" --revision "$REV" \
  --host 127.0.0.1 --port $PORT "$@" > "$D/server.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null || true' EXIT
for i in $(seq 1 180); do curl -sf "http://127.0.0.1:$PORT/health" > /dev/null && break; kill -0 $SRV 2>/dev/null || { tail -40 "$D/server.log"; exit 1; }; sleep 5; done
curl -sf "http://127.0.0.1:$PORT/get_server_info" > "$D/server-info.json" || true
MAXC=1
for C in ${CONC//,/ }; do
  "$VENV/bin/python" -m sglang.bench_serving --backend sglang --base-url "http://127.0.0.1:$PORT" \
    --dataset-name random --random-input-len 256 --random-output-len 512 --random-range-ratio 1.0 \
    --num-prompts $((C * 8 > 16 ? C * 8 : 16)) --max-concurrency $C --output-file "$D/bench.jsonl" > "$D/bench-c$C.txt" 2>&1 || echo "[WARN] bench c=$C failed"
  MAXC=$C
done
"$VENV/bin/python" -m sglang.test.few_shot_gsm8k --host 127.0.0.1 --port $PORT --num-questions 200 --parallel $MAXC \
  > "$D/gsm8k.txt" 2>&1 || echo "[WARN] gsm8k failed"
tail -3 "$D/gsm8k.txt"
