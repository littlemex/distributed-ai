#!/usr/bin/env bash
# mps_bench.sh — measure several vLLM engines sharing one GPU, with and without CUDA MPS.
#
# For each model it runs these modes on the same GPU and the same offered load:
#   single     one engine that gets the whole memory budget
#   timeslice  ENGINES engines side by side, no MPS (the default time-sliced sharing)
#   mps        ENGINES engines side by side under an MPS control daemon
# One load driver sends the same request set to every mode: CONCURRENCY requests in flight in total, dealt round-robin
# to the engines. It timestamps every request, so throughput is measured over one wall-clock window for all engines.
#
# Requirements: one NVIDIA GPU (Volta or newer), nvidia-cuda-mps-control and nvidia-smi on PATH, vLLM, python3 with
# aiohttp (vLLM depends on it), curl, pgrep. No MPS daemon may be running when the script starts.
#
#   MODELS="Qwen/Qwen2.5-0.5B-Instruct" ./mps_bench.sh
set -euo pipefail

MODELS=${MODELS:-"Qwen/Qwen2.5-0.5B-Instruct Qwen/Qwen2.5-1.5B-Instruct Qwen/Qwen2.5-3B-Instruct"}
MODES=${MODES:-"single timeslice mps"}
ENGINES=${ENGINES:-2}
MEM_BUDGET=${MEM_BUDGET:-0.84}        # fraction of GPU memory shared by all engines of a mode
INPUT_LEN=${INPUT_LEN:-512}           # prompt tokens, sent as token ids so the length is exact
OUTPUT_LEN=${OUTPUT_LEN:-128}         # generated tokens, fixed with ignore_eos
CONCURRENCY=${CONCURRENCY:-"16 128"}  # total in-flight requests, one run per value
ROUNDS=${ROUNDS:-10}                  # requests per in-flight slot, so every run lasts about as long
REPEATS=${REPEATS:-3}                 # runs per (mode, concurrency); each repeat uses its own request set
MAX_NUM_SEQS=${MAX_NUM_SEQS:-256}     # per-engine seat count, fixed so it is part of the record
MAX_MODEL_LEN=${MAX_MODEL_LEN:-4096}
ENGINE_ARGS=${ENGINE_ARGS:-}          # extra `vllm serve` arguments, e.g. --enforce-eager
BASE_PORT=${BASE_PORT:-8100}
OUT_DIR=${OUT_DIR:-./results/$(date +%Y%m%d-%H%M%S)}
export CUDA_MPS_PIPE_DIRECTORY=${CUDA_MPS_PIPE_DIRECTORY:-/tmp/nvidia-mps}
export CUDA_MPS_LOG_DIRECTORY=${CUDA_MPS_LOG_DIRECTORY:-/tmp/nvidia-mps-log}

mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "$*"; exit 1; }
PIDS=()
MPS_STARTED=0

for c in nvidia-cuda-mps-control nvidia-smi vllm python3 curl pgrep; do
  command -v "$c" >/dev/null || die "$c not found"
done
for c in $CONCURRENCY; do
  ((c >= ENGINES && c % ENGINES == 0)) || die "CONCURRENCY $c must be a multiple of ENGINES=$ENGINES"
done

# pgrep -x would compare against the 15-character process name and never match the daemon.
mps_daemon_up() { pgrep -f '^nvidia-cuda-mps-control' >/dev/null; }

mps_stop() {
  local t=0
  ((MPS_STARTED)) || return 0
  echo quit | nvidia-cuda-mps-control || true
  while mps_daemon_up; do
    sleep 1; t=$((t + 1))
    ((t <= 30)) || die "MPS daemon still running 30 s after quit"
  done
  MPS_STARTED=0
}

stop_all() {
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
  for p in ${PIDS[@]+"${PIDS[@]}"}; do wait "$p" 2>/dev/null || true; done
  PIDS=()
}

cleanup() { stop_all; mps_stop; }
trap cleanup EXIT

mps_daemon_up && die "an MPS daemon is already running; stop it first so every mode is what it claims"

# Start engines one at a time: vLLM sizes its memory from what is free when it starts.
start_engines() {
  local model=$1 n=$2 util=$3 tag=$4 i port t
  for ((i = 0; i < n; i++)); do
    port=$((BASE_PORT + i))
    # shellcheck disable=SC2086 # ENGINE_ARGS is a list of words by design
    vllm serve "$model" --port "$port" --gpu-memory-utilization "$util" \
      --max-num-seqs "$MAX_NUM_SEQS" --max-model-len "$MAX_MODEL_LEN" --no-enable-prefix-caching \
      $ENGINE_ARGS >"$OUT_DIR/$tag-engine$i.log" 2>&1 &
    PIDS+=($!)
    t=0
    until curl -sf "http://127.0.0.1:$port/health" >/dev/null; do
      sleep 5; t=$((t + 5))
      kill -0 "${PIDS[${#PIDS[@]} - 1]}" 2>/dev/null || die "engine $i died, see $OUT_DIR/$tag-engine$i.log"
      ((t <= 900)) || die "engine $i not ready after 900 s"
    done
    log "engine $i ready on :$port ($tag)"
  done
}

# One driver process loads every engine at once and timestamps each request.
drive() {
  python3 - "$@" <<'PY'
import asyncio, json, random, sys, time
import aiohttp

model, n, conc, rounds, in_len, out_len, seed, out = sys.argv[1:9]
n, conc, rounds, in_len, out_len, seed = map(int, (n, conc, rounds, in_len, out_len, seed))
base = int(sys.argv[9])
rng = random.Random(seed)
# Token ids straight into the prompt: exact length, no tokenizer, no shared prefix between requests.
prompts = [[rng.randrange(1000, 30000) for _ in range(in_len)] for _ in range(conc * rounds)]
queues = [asyncio.Queue() for _ in range(n)]
for k, p in enumerate(prompts):
    queues[k % n].put_nowait(p)
recs = []

async def one(session, port, prompt):
    body = {"model": model, "prompt": prompt, "max_tokens": out_len, "ignore_eos": True, "temperature": 0,
            "stream": True, "stream_options": {"include_usage": True}}
    t0 = time.monotonic(); first = None; tokens = 0
    async with session.post(f"http://127.0.0.1:{port}/v1/completions", json=body) as r:
        r.raise_for_status()
        async for line in r.content:
            line = line.strip()
            if not line.startswith(b"data: ") or line == b"data: [DONE]":
                continue
            d = json.loads(line[6:])
            if d.get("choices") and first is None:
                first = time.monotonic()
            if d.get("usage"):
                tokens = d["usage"]["completion_tokens"]
    recs.append((t0, first or time.monotonic(), time.monotonic(), tokens))

async def worker(session, e):
    while not queues[e].empty():
        await one(session, base + e, queues[e].get_nowait())

async def main():
    timeout = aiohttp.ClientTimeout(total=None)
    async with aiohttp.ClientSession(timeout=timeout, connector=aiohttp.TCPConnector(limit=0)) as s:
        await asyncio.gather(*(worker(s, e) for e in range(n) for _ in range(conc // n)))

wall0, mono0 = time.time(), time.monotonic()
asyncio.run(main())
t0 = min(r[0] for r in recs); t1 = max(r[2] for r in recs)
ttft = sorted((r[1] - r[0]) * 1000 for r in recs)
tpot = sorted((r[2] - r[1]) * 1000 / max(1, r[3] - 1) for r in recs)
res = dict(requests=len(recs), output_tokens=sum(r[3] for r in recs), window_s=t1 - t0,
           output_tok_s=sum(r[3] for r in recs) / (t1 - t0), median_ttft_ms=ttft[len(ttft) // 2],
           median_tpot_ms=tpot[len(tpot) // 2], start_epoch=wall0 + (t0 - mono0), end_epoch=wall0 + (t1 - mono0))
json.dump(res, open(out, "w"))
PY
}

record_meta() {
  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader >"$OUT_DIR/gpu.txt"
  local v
  for v in MODELS MODES ENGINES MEM_BUDGET INPUT_LEN OUTPUT_LEN CONCURRENCY ROUNDS REPEATS MAX_NUM_SEQS \
    MAX_MODEL_LEN ENGINE_ARGS; do
    printf '%s=%s\n' "$v" "${!v}"
  done >"$OUT_DIR/settings.txt"
  printf 'cpus=%s\nvllm=%s\n' "$(nproc)" "$(vllm --version 2>/dev/null | tail -1)" >>"$OUT_DIR/settings.txt"
  log "GPU: $(cat "$OUT_DIR/gpu.txt"), $(tail -2 "$OUT_DIR/settings.txt" | tr '\n' ' ')"
}

record_meta
for model in $MODELS; do
  short=${model##*/}
  for mode in $MODES; do
    n=$ENGINES
    [[ $mode == single ]] && n=1
    util=$(python3 -c "print(round($MEM_BUDGET / $n, 3))")
    if [[ $mode == mps ]]; then
      mkdir -p "$CUDA_MPS_PIPE_DIRECTORY" "$CUDA_MPS_LOG_DIRECTORY"
      : >"$CUDA_MPS_LOG_DIRECTORY/control.log"
      nvidia-cuda-mps-control -d
      MPS_STARTED=1
      sleep 1
      mps_daemon_up || die "MPS daemon did not start"
    elif mps_daemon_up; then
      die "an MPS daemon is running, so '$mode' would not be what it claims"
    fi
    log "== $short $mode: $n engine(s), util $util each"
    start_engines "$model" "$n" "$util" "$short-$mode"
    if [[ $mode == mps ]]; then
      # Every engine process must have registered with the daemon, or the run is not an MPS run.
      clients=$(grep -o 'NEW CLIENT [0-9]*' "$CUDA_MPS_LOG_DIRECTORY/control.log" | sort -u | wc -l)
      ((clients >= n)) || die "only $clients MPS client(s) registered for $n engines"
      echo get_server_list | nvidia-cuda-mps-control >"$OUT_DIR/$short-mps-server.txt"
      cp "$CUDA_MPS_LOG_DIRECTORY/control.log" "$OUT_DIR/$short-mps-control.log"
    fi
    for c in $CONCURRENCY; do
      for ((r = 1; r <= REPEATS; r++)); do
        tag="$short-$mode-c$c-r$r"
        nvidia-smi --query-gpu=timestamp,utilization.gpu --format=csv,noheader,nounits -lms 500 \
          >"$OUT_DIR/$tag-gpu.csv" 2>/dev/null &
        smi=$!
        PIDS+=("$smi")
        drive "$model" "$n" "$c" "$ROUNDS" "$INPUT_LEN" "$OUTPUT_LEN" "$r" "$OUT_DIR/$tag.json" "$BASE_PORT"
        kill "$smi" 2>/dev/null || true
      done
    done
    stop_all
    mps_stop
  done
done

# Mean and spread over the repeats; GPU utilisation only inside each run's own window.
python3 - "$OUT_DIR" <<'PY'
import csv, datetime, glob, json, os, statistics, sys
out = sys.argv[1]
runs = {}
for f in sorted(glob.glob(os.path.join(out, "*-c*-r*.json"))):
    tag = os.path.basename(f)[:-5]
    key, rep = tag.rsplit("-r", 1)
    rest, conc = key.rsplit("-c", 1)
    model, mode = rest.rsplit("-", 1)
    d = json.load(open(f))
    util = []
    for row in csv.reader(open(os.path.join(out, tag + "-gpu.csv"))):
        if len(row) < 2:
            continue
        ts = datetime.datetime.strptime(row[0].strip(), "%Y/%m/%d %H:%M:%S.%f").timestamp()
        if d["start_epoch"] <= ts <= d["end_epoch"]:
            util.append(float(row[1]))
    d["gpu_util"] = statistics.mean(util) if util else float("nan")
    runs.setdefault((model, int(conc), mode), []).append(d)

def agg(rs, k):
    v = [r[k] for r in rs]
    return statistics.mean(v), (statistics.stdev(v) if len(v) > 1 else 0.0)

order = {"single": 0, "timeslice": 1, "mps": 2}
summary = []
for (model, conc, mode), rs in sorted(runs.items(), key=lambda x: (x[0][0], x[0][1], order.get(x[0][2], 9))):
    tok, sd = agg(rs, "output_tok_s")
    summary.append(dict(model=model, concurrency=conc, mode=mode, repeats=len(rs), output_tok_s=round(tok, 1),
                        output_tok_s_sd=round(sd, 1), median_ttft_ms=round(agg(rs, "median_ttft_ms")[0], 1),
                        median_tpot_ms=round(agg(rs, "median_tpot_ms")[0], 2),
                        gpu_util_mean=round(agg(rs, "gpu_util")[0], 1)))
base = {(s["model"], s["concurrency"]): s["output_tok_s"] for s in summary if s["mode"] == "single"}
lines = ["| model | concurrency | mode | output tok/s (mean ± sd) | vs single | median TTFT ms | median TPOT ms | GPU util % |",
         "|---|---|---|---|---|---|---|---|"]
for s in summary:
    b = base.get((s["model"], s["concurrency"]))
    s["vs_single"] = round(s["output_tok_s"] / b, 2) if b else None
    lines.append(f"| {s['model']} | {s['concurrency']} | {s['mode']} | {s['output_tok_s']} ± {s['output_tok_s_sd']} | "
                 f"{s['vs_single']} | {s['median_ttft_ms']} | {s['median_tpot_ms']} | {s['gpu_util_mean']} |")
json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=1)
open(os.path.join(out, "summary.md"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY
echo DONE >"$OUT_DIR/DONE"
