#!/usr/bin/env bash
# E5 multi-seed driver: for each seed, run SGLang generation (system python, has
# sglang) then vLLM teacher-force re-scoring (isolated venv, has vllm). The two
# engines cannot share one process/GPU allocation, hence the two-phase split with
# an explicit engine shutdown between them.
set -u
cd /tmp/e5
export CUDA_VISIBLE_DEVICES=0

for SEED in 42 123; do
  echo "=== [E5] seed=$SEED phase1 (SGLang) $(date -u +%H:%M:%S) ==="
  python3 e5_concordance.py "$SEED" "/tmp/e5/sgl_records_s${SEED}.json" \
      > "/tmp/e5/phase1_s${SEED}.log" 2>&1
  rc1=$?
  echo "  phase1 rc=$rc1"
  if [ $rc1 -ne 0 ]; then echo "  SKIP seed $SEED (phase1 failed)"; continue; fi

  echo "=== [E5] seed=$SEED phase2 (vLLM) $(date -u +%H:%M:%S) ==="
  /tmp/e5/vllm-venv/bin/python e5_concordance_phase2.py "$SEED" \
      "/tmp/e5/sgl_records_s${SEED}.json" "/tmp/e5/summary_s${SEED}.json" \
      > "/tmp/e5/phase2_s${SEED}.log" 2>&1
  echo "  phase2 rc=$?"
  cat "/tmp/e5/summary_s${SEED}.json" 2>/dev/null
done
echo "=== [E5] ALL SEEDS DONE $(date -u +%H:%M:%S) ==="
