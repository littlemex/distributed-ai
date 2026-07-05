#!/bin/bash
# Summarization throughput bench with EXPLICIT token control via vllm bench throughput
# --dataset-name random => exact input/output token counts. Sweeps input_len x output_len.
# Usage: summ_bench_v2.sh <GPU_SPEC> <TAG> <HF_REPO> [EXTRA_VLLM_ARGS...]
set -u
source /opt/pytorch/bin/activate
export HF_HUB_DISABLE_PROGRESS_BARS=1 VLLM_LOGGING_LEVEL=WARNING
GPU=$1; TAG=$2; REPO=$3; shift 3; EXTRA="$@"

IN_LENS=(256 1024 4096)
OUT_LENS=(128 512)
NUM_PROMPTS=500
OUT=~/results_v2_${TAG}.jsonl
LOG=~/summ_v2_${TAG}.log
: > "$OUT"; echo "=== [$TAG] repo=$REPO gpu=$GPU extra=$EXTRA ===" > "$LOG"

for IL in "${IN_LENS[@]}"; do
  for OL in "${OUT_LENS[@]}"; do
    echo "--- throughput IL=$IL OL=$OL ---" >> "$LOG"
    TMPJSON=~/.tmp_${TAG}_${IL}_${OL}.json
    # random dataset varies input length; give generous headroom and pin range-ratio=0
    MML=$(( IL * 2 + OL + 1024 ))
    CUDA_VISIBLE_DEVICES=$GPU vllm bench throughput \
      --model "$REPO" \
      --dataset-name random \
      --input-len $IL --output-len $OL \
      --random-range-ratio 0 \
      --num-prompts $NUM_PROMPTS \
      --max-model-len $MML \
      --gpu-memory-utilization 0.90 \
      --output-json "$TMPJSON" \
      $EXTRA >> "$LOG" 2>&1
    if [ -f "$TMPJSON" ]; then
      python3 -c "
import json
d=json.load(open('$TMPJSON'))
rec={'kind':'summarization','tag':'$TAG','model':'$REPO','gpu_spec':'$GPU',
     'workload':{'input_len':$IL,'output_len':$OL,'num_prompts':$NUM_PROMPTS},
     'throughput':{'total_tok_per_s':round(d.get('tokens_per_second',0),1),
                   'req_per_s':round(d.get('requests_per_second',0),3),
                   'output_tok_per_s':round(d.get('output_tokens_per_second', d.get('output_throughput',0) or 0),1),
                   'elapsed_s':round(d.get('elapsed_time',0),2),
                   'total_tokens':d.get('total_num_tokens',0)}}
print(json.dumps(rec,ensure_ascii=False))
" >> "$OUT" 2>>"$LOG"
      rm -f "$TMPJSON"
    fi
    echo "[done] IL=$IL OL=$OL" >> "$LOG"
  done
done
echo "=== ALL DONE $TAG ===" >> "$LOG"
