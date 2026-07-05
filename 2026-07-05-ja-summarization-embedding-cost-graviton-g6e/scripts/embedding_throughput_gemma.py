#!/usr/bin/env python3
"""EmbeddingGemma-only throughput bench. Fixes the ONNX external-data path-escape
error (HF cache symlink vs ORT security check) by copying .onnx + .onnx_data into
a single flat local dir before loading. Emits JSON Lines matching
embedding_throughput.py schema.

Env: BENCH_INSTANCE, BENCH_HOURLY   Run: python embedding_throughput_gemma.py --n 2000 --threads 32
"""
import json, os, sys, time, argparse, statistics, shutil
import numpy as np

REPO = "onnx-community/embeddinggemma-300m-ONNX"
PREFIX = "title: none | text: "
INPUT_LENS = [32, 128, 512]
BATCHES = [1, 8, 32, 64]

def log(*a): print(*a, file=sys.stderr, flush=True)

def fetch_flat(repo, onnx_rel, workdir):
    """Download onnx + external data into a flat dir; return local .onnx path."""
    from huggingface_hub import hf_hub_download
    os.makedirs(workdir, exist_ok=True)
    onnx_local = hf_hub_download(repo, onnx_rel)
    base = os.path.basename(onnx_rel)
    dst = os.path.join(workdir, base)
    shutil.copyfile(onnx_local, dst)
    dirn = os.path.dirname(onnx_rel)
    for cand in (base + "_data", "model.onnx_data", base.replace('.onnx','') + ".onnx_data"):
        rel = (dirn + "/" + cand) if dirn else cand
        try:
            ext = hf_hub_download(repo, rel)
            shutil.copyfile(ext, os.path.join(workdir, cand)); log(f"  external data: {cand}")
        except Exception:
            pass
    return dst

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
    tok = AutoTokenizer.from_pretrained(REPO)
    so = ort.SessionOptions()
    so.intra_op_num_threads = args.threads; so.inter_op_num_threads = 1
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    base = "日本語の埋め込みモデルをGraviton CPUでバッチ処理する際のスループットを計測する実験用の文です。検索や要約の前処理として大量の文をベクトル化する用途を想定しています。"

    for quant, onnx_rel in (("fp32", "onnx/model.onnx"), ("int8", "onnx/model_quantized.onnx")):
        wd = os.path.expanduser(f"~/egemma_{quant}")
        try:
            local = fetch_flat(REPO, onnx_rel, wd)
            sess = ort.InferenceSession(local, sess_options=so, providers=["CPUExecutionProvider"])
        except Exception as e:
            log(f"[embeddinggemma/{quant}] session FAIL: {e}"); continue
        in_names = {i.name for i in sess.get_inputs()}
        for ilen in INPUT_LENS:
            reps = max(1, (ilen*3)//len(base)+1)
            texts = [PREFIX + base*reps for _ in range(args.n)]
            def run_batch(bt):
                enc = tok(bt, padding="max_length", truncation=True, max_length=ilen, return_tensors="np")
                feed = {}
                for k in ("input_ids","attention_mask","token_type_ids"):
                    if k in in_names:
                        feed[k] = enc[k].astype(np.int64) if k in enc else np.zeros_like(enc["input_ids"], dtype=np.int64)
                return sess.run(None, feed)
            try:
                run_batch(texts[:8]); run_batch(texts[:8])
            except Exception as e:
                log(f"[embeddinggemma/{quant}/L{ilen}] warmup FAIL: {e}"); continue
            for batch in BATCHES:
                sps_runs=[]; lat=[]; ok=True
                for r in range(args.repeats):
                    t0=time.perf_counter(); done=0; l2=[]
                    try:
                        for i in range(0,args.n,batch):
                            b=texts[i:i+batch]; bt0=time.perf_counter(); run_batch(b); l2.append((time.perf_counter()-bt0)*1000); done+=len(b)
                    except Exception as e:
                        log(f"[embeddinggemma/{quant}/L{ilen}/B{batch}] FAIL: {e}"); ok=False; break
                    sps_runs.append(done/(time.perf_counter()-t0)); lat+=l2
                if not ok: continue
                sps=statistics.median(sps_runs); flat=sorted(lat)
                rec={"kind":"embedding","instance":args.instance,"hourly_usd":args.hourly,"model":"embeddinggemma-300m","hf_repo":REPO,"quant":quant,
                     "workload":{"input_len":ilen,"batch":batch,"threads":args.threads,"n":args.n},
                     "throughput":{"sent_per_sec":round(sps,1),"p50_batch_ms":round(flat[len(flat)//2],1),"p99_batch_ms":round(flat[min(len(flat)-1,int(len(flat)*0.99))],1)},
                     "derived":{"usd_per_1M_sent":round(args.hourly/(sps*3600)*1e6,3) if args.hourly else None},"repeats":args.repeats,"value":"median"}
                print(json.dumps(rec,ensure_ascii=False),flush=True)
                log(f"[embeddinggemma/{quant}/L{ilen}/B{batch}] {sps:.1f} sent/s")

if __name__=="__main__":
    main()
