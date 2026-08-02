"""
E5 reversed direction, phase 2: teacher-force the vLLM-generated token sequences
through SGLang and compute the same metrics as the forward direction. Comparing
this against the forward run answers whether the concordance figure depends on
which engine plays the rollout role.

SGLang scores an existing sequence by generating 0 new tokens with
return_logprob=True and logprob_start_len=0, then reading input_token_logprobs.

Guarded under __main__: sgl.Engine spawns subprocesses via multiprocessing
"spawn", which re-imports this file as __main__ in each child.
"""
import json, math, sys, time


def main():
    SEED = int(sys.argv[1]) if len(sys.argv) > 1 else 1234
    IN = sys.argv[2] if len(sys.argv) > 2 else "/tmp/e5/rev_records.json"
    OUT_SUM = sys.argv[3] if len(sys.argv) > 3 else "/tmp/e5/rev_summary.json"

    MODEL = "/fsx/models/Qwen3-4B"
    t0 = time.time()

    with open(IN) as f:
        records = json.load(f)
    print(f"[E5-rev-p2] loaded {len(records)} records", flush=True)

    import sglang as sgl
    engine = sgl.Engine(model_path=MODEL, tp_size=1, mem_fraction_static=0.5,
                        random_seed=SEED, log_level="warning")
    print(f"[E5-rev-p2] SGLang loaded t={time.time()-t0:.1f}s", flush=True)

    full_seqs = [r["prompt_ids"] + r["response_ids"] for r in records]
    out = engine.generate(
        input_ids=full_seqs,
        sampling_params={"max_new_tokens": 0, "temperature": 0.0},
        return_logprob=True,
        logprob_start_len=0,
    )
    print(f"[E5-rev-p2] SGLang scoring done t={time.time()-t0:.1f}s", flush=True)

    pairs = []
    for rec, o in zip(records, out):
        ilp = o["meta_info"].get("input_token_logprobs") or []
        # ilp is aligned to the full sequence; response tokens are the tail
        resp_len = len(rec["response_ids"])
        tail = ilp[len(ilp) - resp_len:] if len(ilp) >= resp_len else []
        sgl_lp = [x[0] for x in tail]
        for a, b in zip(rec["vllm_logprobs"], sgl_lp):
            if a is None or b is None:
                continue
            pairs.append((a, b))  # (vllm = rollout role here, sgl = train-side role)

    engine.shutdown()

    n = len(pairs)
    diffs = [a - b for a, b in pairs]           # rollout(vLLM) - train-side(SGLang)
    mean_diff = sum(diffs) / n
    mean_abs = sum(abs(d) for d in diffs) / n
    k3 = [math.exp(-d) + d - 1 for d in diffs if -20 < d < 20]  # r = train - rollout = -d
    summary = {
        "n_tokens": n,
        "n_sequences": len(records),
        "direction": "vllm_rollout_vs_sglang_trainside",
        "mean_kl_rollout_minus_trainside": mean_diff,
        "mean_abs_diff": mean_abs,
        "k3_kl": sum(k3) / len(k3) if k3 else float("nan"),
        "seed": SEED,
    }
    print("[E5-rev-p2] SUMMARY:", json.dumps(summary, indent=2), flush=True)
    with open(OUT_SUM, "w") as f:
        json.dump(summary, f, indent=2)


if __name__ == "__main__":
    main()
