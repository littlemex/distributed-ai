# Cross-engine concordance harness (SGLang vs vLLM)

Measures the logprob disagreement between two *inference* engines on identical token
sequences, using the same estimator slime uses for `train/mis_kl`
(`examples/train_infer_mismatch_helper/mis.py:add_ppl_metrics`). This isolates
"engine vs engine" from the usual "engine vs trainer" comparison, which answers whether the
benign ~6e-4 baseline mismatch is specific to SGLang or generic to optimised inference
stacks. Results: `../../docs/RESULTS.md`, section "Cross-engine concordance".

## Why two phases and two Python environments

SGLang and vLLM cannot be imported into one process on this image (conflicting torch /
triton / transformers pins), and two engines must not hold GPU memory at the same time.
So the harness runs:

1. `sglang_generate.py` -- **image python** (`python3`, has SGLang). Samples completions and
   records a per-token logprob for every response token, then shuts the engine down.
2. `vllm_rescore.py` -- **isolated venv** (has vLLM). Teacher-forces the exact same
   `prompt + response` token ids through vLLM via `prompt_logprobs=0` and computes the
   metrics.

`run_seeds.sh` chains both phases per seed.

## Setup

```bash
# on a GPU pod with the miles/slime image (SGLang already present)
uv venv --python 3.12 /tmp/e5/vllm-venv
uv pip install --python /tmp/e5/vllm-venv/bin/python vllm==0.11.0
# vllm==0.11.0 pulls transformers 5.x, which its own tokenizer wrapper cannot use
# (Qwen2Tokenizer has no attribute all_special_tokens_extended)
uv pip install --python /tmp/e5/vllm-venv/bin/python "transformers<5"
```

## Run

```bash
mkdir -p /tmp/e5 && cd /tmp/e5
cp <this dir>/*.py <this dir>/run_seeds.sh .
export CUDA_VISIBLE_DEVICES=0
bash run_seeds.sh                     # seeds 42 and 123
# or a single seed:
python3 sglang_generate.py 1234 /tmp/e5/sgl_records.json
/tmp/e5/vllm-venv/bin/python vllm_rescore.py 1234 /tmp/e5/sgl_records.json /tmp/e5/summary.json
```

Each seed writes `summary_s<seed>.json` with `mean_kl_sgl_minus_vllm`, `mean_abs_diff` and
`k3_kl_vllm_train_side`.

## Environment gotchas hit on p5 (H100, CUDA 13.1 driver)

- **`__main__` guard is mandatory** in `sglang_generate.py`. SGLang's `Engine` spawns
  subprocesses with multiprocessing `spawn`, which re-imports the entry file as `__main__`
  in every child; without the guard `sgl.Engine()` itself reruns recursively and the
  schedulers die during init.
- **`enforce_eager=True` is not enough to avoid triton.** vLLM 0.11 still routes some ops
  through dynamo/inductor, and the venv's pinned triton 3.4 rejects the node's CUDA 13.1
  (`Triton only support CUDA 10.0 or higher, but got CUDA version: 13.1`). Upgrading triton
  to 3.6 instead breaks torch 2.8 (`cannot import name 'triton_key'`). The working fix is
  keeping triton 3.4 and setting `TORCHDYNAMO_DISABLE=1` (already set in
  `vllm_rescore.py`) -- a single-token teacher-forced scoring pass needs no compiled
  kernels. Note this means the comparison is against vLLM in eager mode; see the caveat in
  RESULTS.md.
- **vLLM 0.11 dropped `LLM.generate(prompt_token_ids=...)`.** Pass
  `[TokensPrompt(prompt_token_ids=seq), ...]` as the first positional argument instead.
