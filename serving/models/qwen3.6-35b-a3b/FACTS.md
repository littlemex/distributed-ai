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

### Prefix caching: it works, and it took three attempts to find out

Measured three times, and only the third measured the thing.

1. With `--no-enable-prefix-caching` inherited from the dense sibling, the same 37,792-token prompt
   took 4.33 / 4.34 / 4.34 s to first token. That measured a disabled flag, not an architecture.
2. With `enablePrefixCaching: true` in the overlay it took 4.31 / 4.32 / 4.32 s and the engine still
   reported `enable_prefix_caching=False`, which was written up as the engine refusing it. **That was
   wrong.** The chart rendered `--no-enable-prefix-caching` when false and *nothing* when true, and
   vLLM's `enable_prefix_caching` argument is tri-state: `None` means "take the model's default". For
   a hybrid attention model that default is off, in vLLM's own words at
   `engine/arg_utils.py:2604` — *"Hybrid models support prefix caching but keep it opt-in for now
   while the feature matures"*:

   ```python
   default_prefix_caching = (
       model_config.is_prefix_caching_supported and not model_config.is_hybrid
   )
   ```

   For this model those two properties are `True` and `True`. So the capability was there the whole
   time and the flag was never passed. An opt-in needs the flag.
3. With `--enable-prefix-caching` actually on the command line, the engine reports
   `enable_prefix_caching=True`, the KV pool is unchanged at 2,042,667 tokens, and on AgentX's 393
   real Claude Code traces:

| | caching off | caching on |
| --- | --- | --- |
| time to first token, p50 | 6,932 ms | **603 ms** — 11.5x faster |
| time to first token, p90 | 13,369 ms | 3,905 ms |
| request latency, p50 | 11,500 ms | 2,250 ms |
| prompt tokens actually computed, per request | 55,038 | **9,654** — 5.7x fewer |
| cache read tokens | 0 | **3,543,936 of 4,171,465 = 84.96%** |
| box cost per request | $0.0302 | $0.0211 |

84.96% actual against AgentX's 94.14% theoretical is 90.2% of the available reuse. The shortfall is
routing, not the engine: with two replicas behind one Service, a conversation's later turns can land
on the replica that does not hold its prefix, and the live per-replica rates during the run were
86.2% and 66.1%.

The earlier reasoning about *why* it would be all-or-nothing rather than "10 of 40 layers work" was
right, and is the reason the payoff is this large. Rebuilding a linear-attention layer's recurrent
state requires forwarding the prefix from layer one, because layer n's input is layer n−1's output,
so re-using only the full-attention KV would save the KV writes and nothing else. vLLM snapshots the
recurrent state alongside the paged KV, which is why the saving is nearly the whole prefix.

Two consequences for routing. Single-shot short work belongs on this box (its input is
$0.551/Mtok against $1.00 for `claude-haiku-4-5` and $2.20 for `gpt-5.6-terra`). Multi-turn agent
loops belong on an API, whose **cache read** is $0.10 to $0.22 and therefore beats this box's
uncached input. The break-even, with a warm/cold TTFT ratio r, is $0.551 x r: caching would have to
reach r < 0.18 to beat haiku and r < 0.40 to beat terra.

### KV capacity, and the cheaper way to double it

The engine reports 29.71 GiB of KV per rank and **3,092,774 tokens** of GPU KV cache, against about
1.99M on Qwen3.8-27B. That is 40 KiB per token in practice, not the 20 KiB the geometry implies:
`num_kv_heads` is 2 and does not divide `tensor-parallel-size` 4, so vLLM replicates the KV heads
across ranks. Correct, and affordable here, but it is the first thing to check if the cache comes
out smaller than expected. Maximum concurrency at a full 262,144-token request: 11.8x.

The replication is also a lever. **TP=2 removes it** — 40 KiB per token becomes 20 — and at fp8 the
35B weights are about 17.5 GiB a GPU, so two GPUs hold a replica with room for KV. That is the
counterpart to `--kv-cache-dtype fp8`, which buys the same capacity by lowering the precision of
the ten layers this architecture concentrates all of its long-range attention in. Prefer the
configuration change to the numerical one, and if fp8 KV is tried anyway, validate it on long-context
retrieval (needle / RULER) and not only on short tasks.

### Two TP=2 replicas beat one TP=4 replica on the same four GPUs

`num_kv_heads` is 2, so TP=2 divides it and the replication disappears. Measured by redeploying at
`--tp 2` and reading the engine's own report:

| | 1 replica, TP=4, 4 GPUs | 1 replica, TP=2, 2 GPUs | 2 replicas, TP=2, 4 GPUs |
| --- | --- | --- | --- |
| KV per token | 40 KiB | **20.3 KiB** | 20.3 KiB |
| KV cache | 3,092,774 tok | 2,173,090 tok | **4,346,180 tok** |
| prefill, TTFT slope at c=1 | 7,676 tok/s | 7,252 tok/s | — |
| prefill, aggregate at 16 in flight | not measured this way | — | **17,947 tok/s** |
| input $/Mtok at that point | $0.551 (slope, c=1) | $0.583 (slope, c=1) | **$0.236** |
| decode aggregate at c=16 | 1,025 tok/s | 842 tok/s | not measured |

The load-bearing comparison is the second column: **TP=2 on half the GPUs reaches 94% of the prefill
and 82% of the decode of TP=4 on all four**, so per GPU it is nearly twice as productive. Two of them
therefore use the node better than one four-way replica, and the KV they hold between them is 1.41x.

Aggregate prefill for the two-replica configuration, 37,792-token prompts, `max_tokens=1`:

| In flight | Aggregate prefill tok/s | TTFT p50 | Input $/Mtok |
| --- | --- | --- | --- |
| 1 | 8,991 | 4.30 s | 0.470 |
| 2 | 13,557 | 4.50 s | 0.312 |
| 4 | 15,732 | 8.14 s | 0.269 |
| 8 | 16,603 | 15.11 s | 0.255 |
| 16 | 17,947 | 31.26 s | **0.236** |

Reading is therefore about **half the price it was** — $0.236 against $0.551 — with no quantisation
and no quality risk, purely from the tensor-parallel width. It is also the honest place to note what
is not matched: the TP=4 column was measured by the TTFT-slope method at one request in flight and the
two-replica column by aggregate throughput under load, so the ratio mixes two instruments. Re-running
the aggregate probe against TP=4 is the one measurement left to close this comparison.

The TTFT column is the cost of the throughput: a 37,792-token prompt waits 31 seconds at sixteen in
flight. That is prefill queueing, and it is the reason admission needs a threshold rather than a
policy of accepting everything the box can eventually finish.

### Measuring this properly: SGLang's benchmark, and why it did not run here

`sglang.benchmark.serving` (formerly `sglang.bench_serving`) is the right instrument for this and
should be what the harness uses. It drives **any** OpenAI-compatible server — `--backend vllm-chat`
against this box works — and it already has what a hand-rolled probe does not:

- datasets that match the shapes this project cares about: `generated-shared-prefix` (the prefix-cache
  test), `agentic-trace` (multi-turn), `mmmu` and `image` (the vision path), `mooncake` and
  `longbench_v2` (long context), plus `random` with `--random-input-len/--random-output-len`
- `--max-concurrency` and `--request-rate` for closed and open loop, `--output-file` JSONL
- TTFT, TPOT and ITL with p90/p95/p99, request and token throughput, peak output tokens a second
- `--cache-report`, which reports the hit rate with a device/host/storage breakdown

`sglang.test.run_eval` covers part of the quality side too (mmlu, gsm8k, math, gpqa, humaneval,
mgsm, aime25, mmmu, mmmu_pro, longbench_v2) against an arbitrary `--base-url`.

It is not standalone any more: the module imports `sglang.benchmark.datasets`, `sglang.benchmark.utils`
and `sglang.srt.*`, so it needs the package rather than one file. The obvious route — run
`lmsysorg/sglang:latest` as a Job — was **evicted for ephemeral storage** on the CPU node while
pulling the image. Whatever runs it needs a node with disk to spare, requested explicitly as
`ephemeral-storage`, and it must not share a node with the server whose latency it is measuring.

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
- MTP on/off. `profiles.env` defaults to `throughput` (MTP off). Two arguments say that is right
  before any A/B: decode is 0.5% of this workload's tokens, so the ceiling on speeding it up is
  0.5%; and speculative decoding's benefit shrinks as the batch deepens, because at c=16 to 64 the
  GPU is already compute-bound and a rejected draft token is wasted work. MTP is a c=1 to 4
  latency instrument, not a throughput one at this operating point.
- Vision throughput. Image tokens inflate prefill; the OCR family's box time is unmeasured.
