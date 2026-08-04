# [Bug] Qwen3-30B-A3B degenerates into repetition loops when expert-parallel-size > 1

**このファイルは upstream (sglang-project/sglang) へ出す issue のドラフトである。**
未投稿。投稿前に「未検証」節を確認し、必要なら追加測定してから出す。

---

## Summary

On H200, `Qwen3-30B-A3B` produces degenerate repetition loops whenever
`--expert-parallel-size` is greater than 1. The same checkpoint, the same tensor-parallel
degree and the same sampling parameters generate correct output at `ep_size=1`.

The failure scales with the expert-parallel degree: 0%, 59% and 84% of responses degenerate
at EP 1, 2 and 4 respectively, with tensor parallelism held at 8.

## Environment

| | |
|---|---|
| sglang | `0.5.16.dev25+g6460e2c` |
| torch | `2.11.0+cu130` |
| transformers | `5.12.1` |
| flashinfer | `0.6.12` |
| GPU | 8x NVIDIA H200 (143 GB, sm_90), p5en.48xlarge |
| Model | `Qwen/Qwen3-30B-A3B` (bf16, 128 experts, top-8, `moe_intermediate_size=768`) |
| MoE runner | `triton` (also reproduces with the default `auto`) |

## Reproduction

Two runs that differ **only** in `ep_size`:

```python
import sglang as sgl

PROMPTS = [...]  # 32 chat-templated math prompts, any dataset will do
SP = dict(temperature=1.0, top_p=1.0, top_k=-1, max_new_tokens=8192)

# healthy
e = sgl.Engine(model_path="Qwen/Qwen3-30B-A3B", tp_size=8, ep_size=1,
               moe_runner_backend="triton", mem_fraction_static=0.85)
out_ok = e.generate(PROMPTS, SP)

# degenerate
e = sgl.Engine(model_path="Qwen/Qwen3-30B-A3B", tp_size=8, ep_size=2,
               moe_runner_backend="triton", mem_fraction_static=0.85)
out_bad = e.generate(PROMPTS, SP)
```

## Results

`repetition` below is the fraction of the 32 responses whose last 10000 characters compress
by more than 10x under zlib -- a conservative detector, see "Caveat" at the end.
`longest run` is the largest number of consecutive repeats of an identical substring.

| tp_size | ep_size | repetition | longest run | finish reason |
|---|---|---|---|---|
| 1 | 1 | **0.000** | 2 | 24 length, 8 stop |
| 4 | 1 | **0.000** | 2 | 23 length, 9 stop |
| 8 | 1 | **0.000** | 2 | 24 length, 8 stop |
| 4 | 2 | 0.875 | 4083 | 32 length |
| 8 | 2 | 0.594 | 2500 | 31 length, 1 stop |
| 8 | 4 | 0.844 | 3333 | 32 length |

Tensor parallelism does not matter: EP=1 is healthy at TP 1, 4 and 8. Expert parallelism
does: every EP>1 configuration degenerates, and the rate grows with EP.

Example degenerate outputs (all from `tp=4, ep=2`):

```
" think think think think think ..."  x1666
" of the of the of the of the ..."    x1428
"1\n1\n1\n1\n1\n ..."                 x4083
"‖‖‖‖‖‖‖‖‖‖‖ ..."
```

At `ep_size=1` the same prompts are answered correctly:

```
"... So the next 6 cards are placed in boxes: ... $$\boxed{3}$$"
"... Thus, the minimal possible value of d is 10. ... $$\boxed{10}$$"
```

## What is ruled out

- **Sampling parameters.** Reproduces with the model's own recommended settings from
  `generation_config.json` (temperature 0.6 / top_p 0.95 / top_k 20): 0.875, unchanged.
- **MoE runner backend.** Reproduces with the default `auto` as well as explicit `triton`:
  0.844 vs 0.875.
- **The checkpoint.** All 18867 keys in `model.safetensors.index.json` are present
  (48 layers x 128 experts x 3 projections + 48 x 9 + 3), no NaN/Inf/all-zero tensors in
  sampled layers, `tokenizer_config.json` byte-identical to Qwen3-8B's.
- **Response-length limits.** Raising `max_new_tokens` from 8192 to 16384 leaves the
  truncation rate at 0.992 -- generation does not stop, it fills whatever budget it is given.
- **A dense control.** `Qwen3-8B` at tp=4 through the identical code path: 0.000.

## Secondary bug: `tp_size=1, ep_size=2` crashes with ZeroDivisionError

Attempting the reverse configuration fails at startup rather than reporting an invalid
combination:

```
sglang/srt/entrypoints/engine.py:1496 in _compute_parallelism_ranks
    tp_rank
ZeroDivisionError: integer division or modulo by zero
```

Expert parallelism appears to be subordinate to tensor parallelism, so `ep_size > tp_size`
is not expressible -- but the error does not say so. A validation message naming the
constraint would save the next person the same detour.

## Third bug: the deepep path for Qwen3-MoE does not start

Trying to isolate the all-to-all implementation by setting `moe_a2a_backend="deepep"`
(tp=8, ep=2) fails before generation:

```
sglang/srt/models/qwen3_moe.py:382 in forward_deepep
AssertionError: forward_deepgemm_masked is deprecated
```

So `Qwen3MoeSparseMoeBlock.forward_deepep` reaches a deprecated entry point in this build.
This blocks the natural experiment for the report above -- there is no second all-to-all
implementation to compare against.

## Partially investigated

`ep_size > 1` changes at least three things at once. One is ruled out:

1. **experts are split across groups** -- untested
2. **an all-to-all dispatch/combine runs** -- untestable here, see the deepep bug above
3. **each rank holds fewer experts** (64 instead of 128 at EP=2) -- untested
4. **redundant expert placement** -- **ruled out.** `ep_num_redundant_experts=0` still gives
   0.781 at tp=8, ep=2.

Also untested: other MoE models (only Qwen3-30B-A3B here) and other sglang versions.

## Caveat on the metric

The repetition detector ignores responses shorter than 10000 characters, so it
**undercounts**. Four responses in the `tp=4, ep=2` run were classified as non-repeating
while actually repeating `"1\n"` 4083 times, having ended at 8284 characters. The rates
above are lower bounds. The EP=1 rows are not affected in the other direction: 97-100% of
those responses exceed 10000 characters, so 0.000 means they genuinely do not repeat.
