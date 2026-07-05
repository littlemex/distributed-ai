#!/usr/bin/env python3
"""Graviton embedding throughput benchmark (methodology section A).
Sweeps model x quant x input_len x batch, excludes load/warmup, 3-run median.
Emits JSON Lines to stdout (one record per (model,quant,input_len,batch)).
Progress to stderr.

Env:
  BENCH_INSTANCE  instance type label recorded in output (e.g. c8g.8xlarge)
  BENCH_HOURLY    on-demand $/hr for $/1M-sentence derivation
Run:
  python embedding_throughput.py --n 2000 --threads 32 --repeats 3
"""
import json, os, sys, time, argparse, statistics
import numpy as np

# (name, hf_repo, fp32 onnx path, int8 onnx path or None, passage prefix)
MODELS = [
    ("ruri-v3-30m",  "sirasagi62/ruri-v3-30m-ONNX",  "onnx/model.onnx", "onnx/model_int8.onnx", "検索文書: "),
    ("ruri-v3-70m",  "sirasagi62/ruri-v3-70m-ONNX",  "onnx/model.onnx", "onnx/model_int8.onnx", "検索文書: "),
    ("ruri-v3-130m", "sirasagi62/ruri-v3-130m-ONNX", "onnx/model.onnx", "onnx/model_int8.onnx", "検索文書: "),
    ("ruri-v3-310m", "sirasagi62/ruri-v3-310m-ONNX", "onnx/model.onnx", "onnx/model_int8.onnx", "検索文書: "),
    ("me5-small",    "intfloat/multilingual-e5-small","onnx/model.onnx","onnx/model_quantized.onnx","passage: "),
    ("embeddinggemma-300m", "onnx-community/embeddinggemma-300m-ONNX", "onnx/model.onnx", "onnx/model_quantized.onnx", "title: none | text: "),
]

INPUT_LENS = [32, 128, 512]
BATCHES = [1, 8, 32, 64]

def log(*a): print(*a, file=sys.stderr, flush=True)

def build_corpus(n, approx_tok):
    base = "日本語の埋め込みモデルをGraviton CPUでバッチ処理する際のスループットを計測する実験用の文です。検索や要約の前処理として大量の文をベクトル化する用途を想定しています。"
    reps = max(1, (approx_tok * 3) // len(base) + 1)
    return [(base * reps) for _ in range(n)]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=2000)
    ap.add_argument("--threads", type=int, default=os.cpu_count())
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--instance", default=os.environ.get("BENCH_INSTANCE", "unknown"))
    ap.add_argument("--hourly", type=float, default=float(os.environ.get("BENCH_HOURLY", "0")))
    args = ap.parse_args()

    import onnxruntime as ort
    from transformers import AutoTokenizer
    from huggingface_hub import hf_hub_download

    so = ort.SessionOptions()
    so.intra_op_num_threads = args.threads
    so.inter_op_num_threads = 1
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL

    for name, repo, f_fp32, f_int8, prefix in MODELS:
        try:
            tok = AutoTokenizer.from_pretrained(repo)
        except Exception as e:
            log(f"[{name}] tokenizer FAIL: {e}"); continue

        for quant, fpath in (("fp32", f_fp32), ("int8", f_int8)):
            if fpath is None:
                continue
            try:
                local = hf_hub_download(repo, fpath)
                sess = ort.InferenceSession(local, sess_options=so, providers=["CPUExecutionProvider"])
            except Exception as e:
                log(f"[{name}/{quant}] session FAIL: {e}"); continue
            in_names = {i.name for i in sess.get_inputs()}

            for ilen in INPUT_LENS:
                corpus = build_corpus(args.n, ilen)
                texts = [prefix + c for c in corpus]

                def run_batch(bt):
                    enc = tok(bt, padding="max_length", truncation=True, max_length=ilen, return_tensors="np")
                    feed = {}
                    for k in ("input_ids", "attention_mask", "token_type_ids"):
                        if k in in_names:
                            feed[k] = enc[k].astype(np.int64) if k in enc else np.zeros_like(enc["input_ids"], dtype=np.int64)
                    return sess.run(None, feed)

                try:
                    run_batch(texts[:8]); run_batch(texts[:8])  # warmup (excluded)
                except Exception as e:
                    log(f"[{name}/{quant}/L{ilen}] warmup FAIL: {e}"); continue

                for batch in BATCHES:
                    sps_runs = []; lat_runs = []; ok = True
                    for r in range(args.repeats):
                        lat = []; t0 = time.perf_counter(); done = 0
                        try:
                            for i in range(0, args.n, batch):
                                b = texts[i:i+batch]; bt0 = time.perf_counter()
                                run_batch(b); lat.append((time.perf_counter()-bt0)*1000); done += len(b)
                        except Exception as e:
                            log(f"[{name}/{quant}/L{ilen}/B{batch}] run FAIL: {e}"); ok = False; break
                        sps_runs.append(done/(time.perf_counter()-t0)); lat_runs.append(lat)
                    if not ok: continue
                    sps = statistics.median(sps_runs)
                    flat = sorted(sum(lat_runs, []))
                    p50 = flat[len(flat)//2]; p99 = flat[min(len(flat)-1, int(len(flat)*0.99))]
                    rec = {
                        "kind": "embedding", "instance": args.instance, "hourly_usd": args.hourly,
                        "model": name, "hf_repo": repo, "quant": quant,
                        "workload": {"input_len": ilen, "batch": batch, "threads": args.threads, "n": args.n},
                        "throughput": {"sent_per_sec": round(sps,1), "p50_batch_ms": round(p50,1), "p99_batch_ms": round(p99,1)},
                        "derived": {"usd_per_1M_sent": round(args.hourly/(sps*3600)*1e6, 3) if args.hourly else None},
                        "repeats": args.repeats, "value": "median",
                    }
                    print(json.dumps(rec, ensure_ascii=False), flush=True)
                    log(f"[{name}/{quant}/L{ilen}/B{batch}] {sps:.1f} sent/s p50={p50:.1f}ms")

if __name__ == "__main__":
    main()
