"""
E5 phase 2: teacher-force the SGLang-generated (prompt+response) token sequences
through vLLM and extract per-token logprobs via prompt_logprobs. Compute the
mis_kl-equivalent metric (same definition as slime's mis.py add_ppl_metrics):
    kl_per_token = logprob_A - logprob_B   (signed)
    mis_kl (mean, matches slime "kl" convention: rollout - train direction)
    k3_kl = exp(r) - r - 1, r = logprob_train - logprob_rollout
Here we treat SGLang as the "rollout" role (matches training recipe: SGLang is
the actual inference engine used in production) and vLLM as the alternative
"training-side re-score" engine, mirroring the concordance question in the blog.
"""
import json, os, sys, time

# vLLM 0.11 still routes some ops (sampler, logprob gather) through torch.compile /
# dynamo even with enforce_eager=True. The venv's torch/triton pairing on this box
# (CUDA 13.1 driver, torch 2.8.0+cu128 pinned by vllm==0.11.0) chokes on inductor's
# FX graph cache key computation (triton_key import). We don't need any compiled
# kernels for a single-token teacher-forced scoring pass, so hard-disable dynamo.
os.environ["TORCHDYNAMO_DISABLE"] = "1"

SEED_ARG = int(sys.argv[1]) if len(sys.argv) > 1 else 1234
IN = sys.argv[2] if len(sys.argv) > 2 else "/tmp/e5/sgl_records.json"
OUT_SUM = sys.argv[3] if len(sys.argv) > 3 else "/tmp/e5/summary.json"

t0 = time.time()
with open(IN) as f:
    records = json.load(f)
print(f"[E5-p2] loaded {len(records)} sgl records", flush=True)

from vllm import LLM, SamplingParams
from vllm.inputs import TokensPrompt

MODEL = "/fsx/models/Qwen3-4B"
llm = LLM(model=MODEL, tensor_parallel_size=1, gpu_memory_utilization=0.5, enforce_eager=True, seed=SEED_ARG)
print(f"[E5-p2] vLLM loaded t={time.time()-t0:.1f}s", flush=True)

# Teacher-force: feed prompt+response as input, request prompt_logprobs=0 to get
# per-token logprob of every token in the sequence under vLLM's own policy.
full_seqs = [r["prompt_ids"] + r["response_ids"] for r in records]
resp_lens = [len(r["response_ids"]) for r in records]

sp = SamplingParams(max_tokens=1, prompt_logprobs=0, temperature=1.0)
prompts = [TokensPrompt(prompt_token_ids=seq) for seq in full_seqs]
outputs = llm.generate(prompts, sampling_params=sp)
print(f"[E5-p2] vLLM teacher-force scoring done t={time.time()-t0:.1f}s", flush=True)

results = []
for rec, out, resp_len in zip(records, outputs, resp_lens):
    plp = out.prompt_logprobs  # list, index 0 is None (no logprob for first token)
    total_len = len(plp)
    # response tokens occupy the last resp_len positions
    resp_plp = plp[total_len - resp_len:]
    vllm_logprobs = []
    for pos_dict, tok_id in zip(resp_plp, rec["response_ids"]):
        if pos_dict is None or tok_id not in pos_dict:
            vllm_logprobs.append(None)
        else:
            vllm_logprobs.append(pos_dict[tok_id].logprob)
    results.append({
        "sgl_logprobs": rec["sgl_logprobs"],
        "vllm_logprobs": vllm_logprobs,
    })

with open(OUT_SUM.replace("summary","paired_logprobs"), "w") as f:
    json.dump(results, f)
print(f"[E5-p2] wrote paired logprobs, t={time.time()-t0:.1f}s", flush=True)

# ---- compute mis_kl-equivalent metrics ----
import math
diffs = []
for r in results:
    for a, b in zip(r["sgl_logprobs"], r["vllm_logprobs"]):
        if b is None:
            continue
        diffs.append(a - b)  # sgl(rollout) - vllm(alt-train-side)

n = len(diffs)
mean_diff = sum(diffs) / n
mean_abs_diff = sum(abs(d) for d in diffs) / n
# k3_kl with r = vllm - sgl (train - rollout convention, matches loss.py: train_log_prob - rollout_log_prob)
k3_terms = []
for d in diffs:
    r = -d  # vllm - sgl
    if r > 20 or r < -20:
        continue
    k3_terms.append(math.exp(r) - r - 1)
k3_kl = sum(k3_terms) / len(k3_terms) if k3_terms else float("nan")

summary = {
    "n_tokens": n,
    "n_sequences": len(results),
    "mean_kl_sgl_minus_vllm": mean_diff,
    "mean_abs_diff": mean_abs_diff,
    "k3_kl_vllm_train_side": k3_kl,
    "seed": SEED_ARG,
}
print("[E5-p2] SUMMARY:", json.dumps(summary, indent=2), flush=True)
with open(OUT_SUM, "w") as f:
    json.dump(summary, f, indent=2)
