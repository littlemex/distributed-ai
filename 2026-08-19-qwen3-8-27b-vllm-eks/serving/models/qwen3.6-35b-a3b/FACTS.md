# Qwen3.6-35B-A3B — model facts and measurements

Facts about the model and numbers measured on this deployment. Tuning does NOT belong here: it
lives in `values.yaml` and `profiles.env`.

## Facts, from the checkpoint's own config

| | |
| --- | --- |
| Repo served | `Qwen/Qwen3.6-35B-A3B-FP8` (served as `Qwen/Qwen3.6-35B-A3B`) |
| Architecture | `Qwen3_5MoeForConditionalGeneration`, `model_type: qwen3_5_moe` |
| Layers | 40, hidden 2048, 16 attention heads, **2 KV heads**, head_dim 256 |
| Attention | Hybrid: three linear-attention layers then one full attention, ten times over (10 of 40 are full) |
| MoE | 256 experts, 8 per token, moe_intermediate 512, shared expert 512 — about **3B active of 35B** |
| Native window | 262,144. RoPE theta 1e7, partial rotary factor 0.25, interleaved mRoPE |
| Vision | Present: 27 transformer blocks, hidden 1152. **This model reads images**, so the OCR family needs no separate VL deployment |
| Quantisation | FP8 e4m3 dynamic in the checkpoint, with the vision blocks excluded |

## Measured on this deployment (2026-08-27, g6e.12xlarge, 4x L40S, $15.2174/h, TP=4, 262k window)

### Reading a prompt

Prompt lengths 1,902 / 8,902 / 37,792 / 94,462 / 188,912 tokens, `max_tokens=1`, one request in
flight, TTFT against prompt length by least squares.

| | Qwen3.6-35B-A3B | Qwen3.8-27B | ratio |
| --- | --- | --- | --- |
| prefill | **7,676 tok/s** | 2,129 tok/s | 3.6x |
| input price from the hourly rate | **$0.551/Mtok** | $1.986/Mtok | 0.28x |

The active-parameter ratio (27B dense against 3B active) would suggest nine-fold. It is 3.6, and the
gap is MoE routing, small per-expert GEMMs, TP communication and memory bandwidth. Worth recording
because the FLOPs ratio is an upper bound, not a prediction.

### Writing tokens

Short prompt, 256 output tokens, aggregate over the requests in flight.

| In flight | Aggregate tok/s | Per request tok/s | TTFT p50 | Output $/Mtok | Qwen3.8-27B $/Mtok |
| --- | --- | --- | --- | --- | --- |
| 1 | 135.8 | 136.6 | 0.05 s | 31.12 | 38.54 |
| 8 | 644.1 | 82.8 | 0.15 s | 6.56 | ~25 |
| 16 | 1,024.8 | 65.0 | 0.18 s | **4.12** | 13.78 |
| 32 | 1,156.6 | 48.1 | 0.24 s | 3.65 | 11.98 |
| 48 | 1,219.3 | 28.2 | 5.61 s | 3.47 | 10.68 |
| 64 | 1,262.9 | 23.7 | 5.57 s | 3.35 | 10.44 |

The knee is around 16 to 32. Past 32 aggregate throughput gains 5% while TTFT jumps from 0.24 s to
5.6 s, which is queueing rather than work.

### Prefix caching: still unavailable

The same 37,792-token prompt sent three times took 4.33 s, 4.34 s, 4.34 s to first token —
**1.00x**. The linear-attention layers hold a recurrent state that cannot be re-used, as on the
dense sibling. Measured rather than inferred from the architecture, and it is why
`enablePrefixCaching` stays false. Do not advertise cheap repeated prompts for this model.

### KV capacity

The engine reports 29.71 GiB of KV per rank and **3,092,774 tokens** of GPU KV cache, against about
1.99M on Qwen3.8-27B. That is 40 KiB per token in practice, not the 20 KiB the geometry implies:
`num_kv_heads` is 2 and does not divide `tensor-parallel-size` 4, so vLLM replicates the KV heads
across ranks. Correct, and affordable here, but it is the first thing to check if the cache comes
out smaller than expected. Maximum concurrency at a full 262,144-token request: 11.8x.

## What this means for routing

Per token, at the c=16 operating point, this box is cheaper than every API in the roster on both
sides — input $0.551 against $2.20 for `gpt-5.6-terra` and $1.00 for `claude-haiku-4-5`, output
$4.12 against $13.20 and $5.00. The exception is the one that matters for agents: a provider's
**cache read** is $0.22 (terra) or $0.10 (haiku), which beats this box's $0.551 for input that
repeats. So single-shot work with short prompts belongs here, and multi-turn loops whose prompt is
re-sent every turn belong on an API until prefix caching works on this architecture.

## Not yet measured

- Quality. Nothing here says whether the model is any good; the canary suite (classification,
  extraction, translation, summarisation, OCR, GAIA L1, a small SWE-bench sample) has not run.
- MTP on/off. `profiles.env` defaults to `throughput` (MTP off) on the argument that this workload's
  decode is a rounding error, but the A/B has not been run on this model.
- Vision throughput. Image tokens inflate prefill; the OCR family's box time is unmeasured.
