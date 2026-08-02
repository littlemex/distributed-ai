#!/usr/bin/env bash
# E5 across model scales: same harness, same seed, three dense Qwen3 sizes.
# Answers whether the cross-engine concordance figure is specific to the 4B model
# that every other measurement in this study used.
set -u
cd /tmp/e5
export CUDA_VISIBLE_DEVICES=0
SEED=1234
for M in Qwen3-1.7B Qwen3-4B Qwen3-8B; do
  MP=/fsx/models/$M
  [ -f "$MP/config.json" ] || { echo "SKIP $M (not staged)"; continue; }
  echo "=== [E5-model] $M phase1 (SGLang) $(date -u +%H:%M:%S) ==="
  E5_MODEL="$MP" E5_N_PROMPTS=128 timeout 600 python3 e5_concordance.py "$SEED" \
      "/tmp/e5/mdl_${M}.json" > "/tmp/e5/mdl_p1_${M}.log" 2>&1
  echo "  phase1 data=$(ls -la /tmp/e5/mdl_${M}.json 2>/dev/null | awk '{print $5}') bytes"
  [ -s "/tmp/e5/mdl_${M}.json" ] || { echo "  SKIP $M (no data)"; continue; }

  echo "=== [E5-model] $M phase2 (vLLM) $(date -u +%H:%M:%S) ==="
  E5_MODEL="$MP" timeout 900 /tmp/e5/vllm-venv/bin/python e5_concordance_phase2.py "$SEED" \
      "/tmp/e5/mdl_${M}.json" "/tmp/e5/mdl_summary_${M}.json" > "/tmp/e5/mdl_p2_${M}.log" 2>&1
  echo "  phase2 rc=$?"
  pkill -9 -f "VLLM::EngineCore" 2>/dev/null || true
  sleep 8
  cat "/tmp/e5/mdl_summary_${M}.json" 2>/dev/null; echo
done
echo "=== [E5-model] DONE $(date -u +%H:%M:%S) ==="
