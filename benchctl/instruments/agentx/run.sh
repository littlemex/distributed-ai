#!/usr/bin/env bash
# Run SemiAnalysis AgentX against the box, using their harness rather than an imitation of it.
#
# AgentX is AIPerf's `inferencex-agentx-mvp` scenario replaying 393 anonymised Claude Code traces:
# multi-turn agentic coding, ~101,000 input tokens per request on average, 99.15% of all tokens on the
# input side. That last figure is worth pausing on — an independent corpus reproducing the 99.5% this
# project measured on its own SWE-bench episodes — because it means the benchmark is aimed squarely at
# the property this box is worst at. vLLM refuses prefix caching on a hybrid-attention model, and
# AgentX's whole premise is a 95%+ cache hit rate.
#
# The flags below are copied from InferenceX's own `build_replay_cmd`, deliberately and with the same
# values, because the point of adopting a standard benchmark is comparability. Every deviation is
# listed in DEVIATIONS at the end of the run and written into the artifact, so a number from here can
# never be quietly compared against a published one it is not commensurate with.
set -euo pipefail

INFERENCEX_REPO="${INFERENCEX_REPO:-https://github.com/SemiAnalysisAI/InferenceX.git}"
INFERENCEX_REF="${INFERENCEX_REF:-1d06f3604d41305e05f2b27a404ae256cfbc4363}"
WORK="${WORK:-/scratch/agentx}"
OUT="${OUT:?OUT (artifact dir on the shared volume) is required}"
MODEL="${MODEL:?}"                       # HF id, used for the tokenizer
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-$MODEL}"
URL="${URL:?}"                           # http://host:port
CONC="${CONC:-1}"
DURATION="${DURATION:-300}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
LOADER="${LOADER:-semianalysis_cc_traces_weka_062126_256k}"
DATASET="${DATASET:-semianalysisai/cc-traces-weka-062126-256k}"
WARMUP_PER_LANE="${WARMUP_PER_LANE:-1}"
SERVER_METRICS_URLS="${SERVER_METRICS_URLS:-}"   # comma-separated Prometheus endpoints, one per replica
HOURLY_USD="${HOURLY_USD:-15.2174}"

mkdir -p "$WORK" "$OUT"
export HF_HOME="${HF_HOME:-$WORK/hf}"
export TMPDIR="${TMPDIR:-$WORK/tmp}"
mkdir -p "$HF_HOME" "$TMPDIR"

log(){ printf '\n[agentx] %s\n' "$*"; }

log "disk before: $(df -h "$WORK" | awk 'NR==2{print $4" free of "$2}')"

log "clone $INFERENCEX_REF"
if [ ! -d "$WORK/InferenceX/.git" ]; then
  git clone -q "$INFERENCEX_REPO" "$WORK/InferenceX"
fi
cd "$WORK/InferenceX"
git fetch -q origin "$INFERENCEX_REF" 2>/dev/null || git fetch -q origin
git checkout -q "$INFERENCEX_REF"
git submodule update -q --init --depth 1 utils/aiperf
INFERENCEX_SHA="$(git rev-parse HEAD)"
AIPERF_SHA="$(git -C utils/aiperf rev-parse HEAD)"
log "InferenceX $INFERENCEX_SHA / aiperf $AIPERF_SHA"

# Isolated interpreter, for their reason and not just tidiness: AIPerf shares no site-packages with
# anything, so installing it can never upgrade a server's transformers or fastapi underneath it.
log "install aiperf into an isolated venv"
export UV_CACHE_DIR="$WORK/uv-cache"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR="$WORK/uv/bin" sh >/dev/null
  export PATH="$WORK/uv/bin:$PATH"
fi
VENV="$WORK/venv"
[ -x "$VENV/bin/aiperf" ] || {
  uv venv --python 3.11 "$VENV" >/dev/null
  uv pip install -q --python "$VENV/bin/python" \
    -r utils/agentic-benchmark/requirements.txt \
    -e utils/aiperf \
    "datasets>=4.7.0" "huggingface_hub[cli]>=0.25.0" urllib3 requests
}
AIPERF="$VENV/bin/aiperf"
[ -x "$AIPERF" ] || { echo "[agentx] ERROR: aiperf missing at $AIPERF" >&2; exit 1; }
"$AIPERF" --version 2>/dev/null | head -2 || true

log "download traces: $DATASET (loader $LOADER)"
"$VENV/bin/hf" download --repo-type dataset "$DATASET" >/dev/null

RESULT_DIR="$WORK/result"
rm -rf "$RESULT_DIR"; mkdir -p "$RESULT_DIR"

# Their scenario refuses a profile shorter than 900 s without an explicit override, and marks such a
# run invalid for submission. A short arm is a smoke test and is labelled one.
UNSAFE=""
if [ "$DURATION" -lt 900 ]; then
  UNSAFE="--unsafe-override"
  log "duration ${DURATION}s < 900s: passing --unsafe-override; this run is NOT canonical"
fi

METRICS_ARGS=()
if [ -n "$SERVER_METRICS_URLS" ]; then
  METRICS_ARGS=(--server-metrics)
  IFS=',' read -r -a _urls <<< "$SERVER_METRICS_URLS"
  for u in "${_urls[@]}"; do [ -n "$u" ] && METRICS_ARGS+=("$u"); done
fi

# Their defaults, verbatim. AIPERF_DATASET_WEKA_LIVE_ASSISTANT_RESPONSES=0 means recorded assistant
# responses build later turns and live output is measured but discarded, which is what keeps the
# replayed prompt shapes identical across engines.
export AIPERF_DATASET_WEKA_LIVE_ASSISTANT_RESPONSES=0
export AIPERF_DATASET_CONFIGURATION_TIMEOUT=1800
export AIPERF_SERVICE_PROFILE_CONFIGURE_TIMEOUT=1800
export AIPERF_UI_REALTIME_METRICS_ENABLED=true

log "profile: conc=$CONC duration=${DURATION}s against $URL (live log at $OUT/aiperf.log)"
set -x
"$AIPERF" profile --scenario inferencex-agentx-mvp \
  --url "$URL" \
  --endpoint /v1/chat/completions \
  --endpoint-type chat \
  --streaming \
  --model "$SERVED_MODEL_NAME" \
  --tokenizer "$MODEL" \
  --tokenizer-trust-remote-code \
  --concurrency "$CONC" \
  --benchmark-duration "$DURATION" \
  --stats-interval 30 \
  --random-seed 42 \
  --failed-request-threshold 0.10 \
  --trajectory-start-min-ratio 0.25 \
  --trajectory-start-max-ratio 0.75 \
  --warmup-requests-per-lane "$WARMUP_PER_LANE" \
  --trace-idle-gap-cap-seconds 300 \
  --warmup-grace-period 1800 \
  --use-server-token-count \
  --no-gpu-telemetry \
  --public-dataset "$LOADER" \
  --max-context-length "$MAX_MODEL_LEN" \
  --num-dataset-entries 393 \
  --slice-duration 1.0 \
  "${METRICS_ARGS[@]}" \
  --output-artifact-dir "$RESULT_DIR/aiperf_artifacts" \
  $UNSAFE 2>&1 | tee "$OUT/aiperf.log" | tail -400
set +x

# Their aggregator, not a reimplementation of their statistics. `utils/` has no __init__.py, so
# `python -m utils.agentic...` cannot resolve it; the module is invoked by path with the repo root on
# PYTHONPATH so its own intra-package imports still work.
log "aggregate with InferenceX's own aggregator"
RESULT_FILENAME="agentx_conc${CONC}" RESULT_DIR="$RESULT_DIR" AGENTIC_OUTPUT_DIR="$OUT" \
  PYTHONPATH="$WORK/InferenceX" "$VENV/bin/python" \
  "$WORK/InferenceX/utils/agentic/aggregation/process_agentic_result.py" || {
    echo "[agentx] WARNING: aggregation failed; raw artifacts are still preserved" >&2; }

log "copy raw artifacts and provenance"
mkdir -p "$OUT/raw"
cp -r "$RESULT_DIR/aiperf_artifacts" "$OUT/raw/" 2>/dev/null || true
cat > "$OUT/provenance.json" <<JSON
{
  "instrument": "SemiAnalysis AgentX (AIPerf scenario inferencex-agentx-mvp)",
  "inferencex_commit": "$INFERENCEX_SHA",
  "aiperf_commit": "$AIPERF_SHA",
  "dataset": "$DATASET",
  "loader": "$LOADER",
  "concurrency": $CONC,
  "benchmark_duration_s": $DURATION,
  "warmup_requests_per_lane": $WARMUP_PER_LANE,
  "max_context_length": $MAX_MODEL_LEN,
  "served_model_name": "$SERVED_MODEL_NAME",
  "tokenizer": "$MODEL",
  "server_metrics_urls": "$SERVER_METRICS_URLS",
  "box_hourly_usd": $HOURLY_USD,
  "canonical": $([ -z "$UNSAFE" ] && echo true || echo false),
  "deviations": [
    "Box is 4x L40S at TP=2 x 2 replicas, not a published AgentX platform. Absolute numbers are not comparable to the leaderboard; the shape of the curve and the KV-cache figures are.",
    "Model is Qwen3.6-35B-A3B-FP8, which is not an AgentX reference model, so the corpus is the 256k-capped variant selected by the harness for non-1M-context families.",
    "vLLM reports enable_prefix_caching=False for this hybrid-attention model, so the 95%+ cache hit rate AgentX is designed around cannot occur here. That is the measurement, not a misconfiguration.",
    "$([ -z "$UNSAFE" ] && echo "none: duration met the scenario minimum" || echo "benchmark-duration below the scenario minimum of 900s, run with --unsafe-override and NOT valid for submission")"
  ]
}
JSON
log "disk after: $(df -h "$WORK" | awk 'NR==2{print $4" free of "$2}')"
log "done -> $OUT"
ls -la "$OUT" | head -20
