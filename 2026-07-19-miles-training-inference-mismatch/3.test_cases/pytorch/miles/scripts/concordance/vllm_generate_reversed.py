"""
E5 reversed direction, phase 1: vLLM generates, so the roles of the two engines
are swapped relative to e5_concordance.py. Checks that the measured concordance
is a property of the engine *pair*, not of which engine happens to play the
rollout role.

vLLM must run eager on this box (its pinned torch 2.8 / triton 3.4 cannot compile
against the node's CUDA 13.1 driver), hence TORCHDYNAMO_DISABLE + enforce_eager.
Output: token ids + vLLM's own per-token logprobs for the sampled responses.
"""
import json, os, sys, time

os.environ["TORCHDYNAMO_DISABLE"] = "1"

SEED = int(sys.argv[1]) if len(sys.argv) > 1 else 1234
OUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/e5/rev_records.json"
N_PROMPTS = int(os.environ.get("E5_N_PROMPTS", "32"))

MODEL = "/fsx/models/Qwen3-4B"
DATA = "/fsx/data/dapo-math-17k/dapo-math-17k.jsonl"
MAX_NEW_TOKENS = 256

t0 = time.time()

prompts = []
with open(DATA) as f:
    for line in f:
        prompts.append(json.loads(line))
        if len(prompts) >= N_PROMPTS:
            break

from transformers import AutoTokenizer
tok = AutoTokenizer.from_pretrained(MODEL)
chat_texts = [tok.apply_chat_template(p["prompt"], tokenize=False, add_generation_prompt=True)
              for p in prompts]
prompt_ids = [tok(t, add_special_tokens=False)["input_ids"] for t in chat_texts]
print(f"[E5-rev] {len(prompt_ids)} prompts tokenized", flush=True)

from vllm import LLM, SamplingParams
from vllm.inputs import TokensPrompt

llm = LLM(model=MODEL, tensor_parallel_size=1, gpu_memory_utilization=0.5,
          enforce_eager=True, seed=SEED)
print(f"[E5-rev] vLLM loaded t={time.time()-t0:.1f}s", flush=True)

# logprobs=0 returns the logprob of each *sampled* token as generation proceeds.
sp = SamplingParams(temperature=1.0, top_p=1.0, max_tokens=MAX_NEW_TOKENS, logprobs=0, seed=SEED)
outs = llm.generate([TokensPrompt(prompt_token_ids=p) for p in prompt_ids], sampling_params=sp)
print(f"[E5-rev] vLLM generate done t={time.time()-t0:.1f}s", flush=True)

records = []
for pid, out in zip(prompt_ids, outs):
    comp = out.outputs[0]
    resp_ids = list(comp.token_ids)
    lps = []
    for tok_id, pos in zip(resp_ids, comp.logprobs or []):
        lps.append(pos[tok_id].logprob if (pos and tok_id in pos) else None)
    # drop trailing positions we could not score
    keep = [i for i, v in enumerate(lps) if v is not None]
    if not keep:
        continue
    n = keep[-1] + 1
    records.append({"prompt_ids": pid, "response_ids": resp_ids[:n],
                    "vllm_logprobs": lps[:n]})

n_tok = sum(len(r["response_ids"]) for r in records)
print(f"[E5-rev] {len(records)} sequences, {n_tok} response tokens", flush=True)
with open(OUT, "w") as f:
    json.dump(records, f)
print(f"[E5-rev] wrote {OUT} t={time.time()-t0:.1f}s", flush=True)
