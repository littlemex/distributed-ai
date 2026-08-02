"""
E5: SGLang vs vLLM offline logprob concordance (mis_kl-equivalent), on the same
GPU pod used for the miles/slime experiments. Same model (Qwen3-4B), same
dapo-math-17k prompts, same chat template, temperature matching the training
recipe's rollout config (temperature=1.0).

Procedure (mirrors slime's mis.py add_ppl_metrics "kl" metric, but between two
inference engines instead of train-vs-rollout):
  1. Sample completions with SGLang (on-policy rollout, matches training recipe).
  2. Re-score the exact same token sequences (prompt+response) under vLLM via
     teacher-forced prompt_logprobs.
  3. mis_kl-equivalent := mean over response tokens of (logprob_sglang - logprob_vllm)
     (signed, matches slime's "kl" estimator direction convention: rollout - train)
     also report mean |diff| and k3_kl = exp(r) - r - 1 with r = logprob_vllm - logprob_sglang.

Output: /tmp/e5/sgl_records.json (phase 1 of 2; phase 2 does vLLM re-scoring)

NOTE: guarded under __main__ because SGLang's Engine launches subprocesses via
multiprocessing "spawn", which re-imports this file as __main__ in each child.
Without the guard, module-level code (including sgl.Engine() itself) reruns
recursively in every child process.
"""
import json, sys, time, gc


def main():
    SEED_ARG = int(sys.argv[1]) if len(sys.argv) > 1 else 1234
    OUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/e5/sgl_records.json"
    MODEL = "/fsx/models/Qwen3-4B"
    DATA = "/fsx/data/dapo-math-17k/dapo-math-17k.jsonl"
    N_PROMPTS = 32
    MAX_NEW_TOKENS = 256
    TEMPERATURE = 1.0
    SEED = SEED_ARG

    t0 = time.time()

    prompts = []
    with open(DATA) as f:
        for line in f:
            prompts.append(json.loads(line))
            if len(prompts) >= N_PROMPTS:
                break
    print(f"[E5] loaded {len(prompts)} prompts", flush=True)

    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(MODEL)

    chat_texts = [
        tok.apply_chat_template(p["prompt"], tokenize=False, add_generation_prompt=True)
        for p in prompts
    ]
    prompt_ids = [tok(t, add_special_tokens=False)["input_ids"] for t in chat_texts]
    print(f"[E5] tokenized, avg prompt len={sum(len(x) for x in prompt_ids)/len(prompt_ids):.1f}", flush=True)

    import sglang as sgl

    print(f"[E5] loading SGLang engine... t={time.time()-t0:.1f}s", flush=True)
    sgl_engine = sgl.Engine(model_path=MODEL, tp_size=1, mem_fraction_static=0.5, random_seed=SEED, log_level="warning")

    sampling_params = {"temperature": TEMPERATURE, "max_new_tokens": MAX_NEW_TOKENS, "top_p": 1.0}
    gen_out = sgl_engine.generate(
        input_ids=prompt_ids,
        sampling_params=sampling_params,
        return_logprob=True,
        logprob_start_len=0,
    )
    print(f"[E5] SGLang generate done t={time.time()-t0:.1f}s", flush=True)

    records = []
    for i, out in enumerate(gen_out):
        resp_ids = out["output_ids"]
        olp = out["meta_info"]["output_token_logprobs"]
        if len(olp) != len(resp_ids):
            n = min(len(olp), len(resp_ids))
            resp_ids = resp_ids[:n]
            olp = olp[:n]
        sgl_logprobs = [x[0] for x in olp]
        records.append({
            "prompt_ids": prompt_ids[i],
            "response_ids": resp_ids,
            "sgl_logprobs": sgl_logprobs,
        })

    n_resp_tokens = sum(len(r["response_ids"]) for r in records)
    print(f"[E5] collected {len(records)} sequences, {n_resp_tokens} response tokens total", flush=True)

    sgl_engine.shutdown()
    del sgl_engine
    gc.collect()
    print(f"[E5] SGLang engine shut down t={time.time()-t0:.1f}s", flush=True)

    with open(OUT, "w") as f:
        json.dump(records, f)
    print(f"[E5] wrote {OUT}", flush=True)


if __name__ == "__main__":
    main()
