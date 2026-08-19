#!/usr/bin/env bash
# vLLM online-serving benchmark (throughput / TTFT / TPOT / ITL). Runs `vllm bench serve`
# INSIDE the serving pod against localhost:8000 (the vLLM image + weights are already there,
# so no extra image pull / port-forward). Slight CPU contention with the server is acceptable.
#
#   KCTX=distai-tokyo NAMESPACE=distai ./run_bench.sh [CONCURRENCY] [NUM_PROMPTS] [IN_LEN] [OUT_LEN]
#   sweep:  for c in 1 2 4 8 16 32 64; do ./run_bench.sh $c $((c*8)) 1024 256; done
set -euo pipefail
KCTX="${KCTX:-distai-tokyo}"; NAMESPACE="${NAMESPACE:-distai}"; MODEL="${MODEL:-Qwen/Qwen3.8-27B}"
SEL="${SEL:-app.kubernetes.io/instance=vllm-qwen-qwen3-8-27b}"
CONC="${1:-32}"; NUM="${2:-$((CONC*8))}"; IN="${3:-1024}"; OUT="${4:-256}"
K=(kubectl --context "$KCTX" -n "$NAMESPACE")
POD="$("${K[@]}" get pods -l "$SEL" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
echo "=== bench pod=$POD c=$CONC num=$NUM in=$IN out=$OUT ==="
"${K[@]}" exec "$POD" -- vllm bench serve --backend openai-chat --model "$MODEL" \
  --base-url "${TARGET:-http://localhost:8000}" --endpoint /v1/chat/completions \
  --dataset-name random --num-prompts "$NUM" --max-concurrency "$CONC" \
  --random-input-len "$IN" --random-output-len "$OUT" \
  --percentile-metrics ttft,tpot,itl,e2el --ignore-eos 2>&1 \
  | grep -iE "Successful|throughput|Mean TTFT|Median TTFT|P99 TTFT|Mean TPOT|Median TPOT|Benchmark duration|Total Token|Output token" | tail -30
