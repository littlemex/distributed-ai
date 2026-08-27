# The hardware view, and which of these findings travel

Two questions, put to both advisors and then tested where testing was cheap: what do the published GPU
numbers say that the throughput numbers do not, and which of this project's conclusions are about this
model on this GPU with this configuration rather than about serving in general.

Specs both advisors relied on, stated so the arithmetic can be checked: **NVIDIA L40S, 362 TFLOP/s dense
BF16, 733 TFLOP/s dense FP8, 864 GB/s GDDR6, 48 GB, no NVLink — inter-GPU traffic is PCIe Gen4 x16**, and
that last one matters because every tensor-parallel all-reduce on this box crosses it.

## The roofline, and the error in my own first pass

Measured: prefill up to 18,520 tokens/s aggregate, decode 1,263 tokens/s aggregate at 64 in flight, model
Qwen3.6-35B-A3B-FP8 with ~3B active of 35B stored.

**Prefill, by hand first.** 18,520 × 2 FLOP × 3e9 active parameters = 111 TFLOP/s aggregate,
**27.8 TFLOP/s per GPU** — 3.8% against 733, 7.7% against 362, with 362 the more honest denominator
because vLLM's Ada FP8 MoE path may dequantise before the matmul.

**Prefill, by the engine, which is 2.2x higher.** `--enable-mfu-metrics` is now on, so the engine accounts
for its own FLOPs and bytes and there is no need to guess. Over one 57.8-second arm on fresh pods (so the
cumulative counters are that arm), 747,510 prompt tokens produced:

| | engine-reported |
| --- | --- |
| FLOP/s | 248.2 TFLOP/s aggregate, **62.0 TFLOP/s per GPU** |
| MFU vs dense FP8 733 | **8.5%** |
| MFU vs dense BF16 362 | **17.1%** |
| Bytes read | 319 GB/s aggregate, 80 GB/s per GPU → **MBU 9.2%** |
| FLOP per prompt token | **19.2 GFLOP**, against the 6.0 a 2 × 3e9 estimate gives |

The engine counts 3.2x more FLOPs per token than "two per active parameter", because that formula omits
attention entirely and this arm ran 40,000-token prompts through ten full-attention layers. So the honest
figure is **8.5 to 17.1% MFU, not 3.8 to 7.7%** — still low, still a software ceiling rather than a hardware
one, but a third of the way up rather than a twentieth.

Two hand estimates, two corrections, both upward and both from the same cause: a mental model of the
model's cost that was simpler than the model. Worth stating as a rule — **read the engine's own counters
before drawing a roofline**, and note that they are off by default and read a flat 0.0 until enabled, which
is indistinguishable from an idle engine.

**Decode, and here my arithmetic was wrong in a way worth keeping.** I computed 3 GB of active weights
read per step, giving ~3.5% memory-bandwidth utilisation. That model is only correct at one request in
flight. At 64, each token routes to its own experts, so a step reads the **union** of experts touched:

```
unique experts per layer ≈ 256 × (1 − (1 − 8/256)^64) ≈ 222 of 256 ≈ 87%
bytes per step ≈ 0.87 × 33 GB (experts) + ~2 GB (dense) ≈ 31 GB, not 3 GB
```

At ~20 steps/s that is ~610 GB/s aggregate, ~150 GB/s per GPU, **MBU ≈ 18%** — bad, not catastrophic.
Both advisors reached the mid-teens independently.

That correction generalises, and it is the most portable thing in this document:

> **A MoE's "only the active parameters" advantage disappears as the decode batch grows.**
> `bytes/step ≈ E_total × (1 − (1 − k/E)^B) × bytes_per_expert + dense`. At B=64 with k/E=1/32 the engine is
> reading essentially the whole model, so a roofline drawn against active parameters is wrong by an order
> of magnitude. This box's memory-bound decode ceiling is 864×4 / 31 GB ≈ 111 steps/s ≈ 7,100 tokens/s
> against 1,263 measured.

## The suspect both advisors ranked first, tested and refuted

The leading hypothesis for single-digit prefill MFU was fine-grained MoE GEMM: at a 2,048-token step each
expert sees only 2048 × 8/256 = 64 rows, which cannot fill a Tensor Core. The stated test was a step-budget
sweep — rising strongly confirms granularity, flat points at communication or launch overhead.

Same shape throughout (40,000 input, 8 output, 4 in flight, unique salted prefixes so the cache is not
being measured):

| `max_num_batched_tokens` | `long_prefill_token_threshold` | read tokens/s | req/hour | TTFT p50 |
| --- | --- | --- | --- | --- |
| 16,384 | off | 12,320 | 949 | 10.03 s |
| 16,384 | 2,048 | **13,474** | 1,038 | 12.32 s |
| 16,384 | 2,048 (repeat) | 13,238 / 12,939 | 1,020 / 997 | 12.31 / 12.40 s |
| 2,048 | off | 13,238 | 1,020 | 12.31 s |

Three runs of the same configuration came out at 13,474 / 13,238 / 12,939 tokens/s, so the run-to-run
spread is about 4% and the 8x step-budget change sits inside twice that.

**An eight-fold change in step budget moves prefill throughput by under 10%. The granularity hypothesis is
refuted for this shape**, and by the advisors' own criterion the remaining suspects are communication
(PCIe all-reduce, no NVLink) and kernel launch or the Gated DeltaNet layers that make up 30 of 40.

A second result falls out that matters operationally. `long_prefill_token_threshold=2048`, adopted to
protect a short family's latency, is **9% faster than not having it** at this shape — the co-residency fix
costs no throughput. The arithmetic explains both halves at once: with the cap, four requests contribute
2,048 tokens each and a step still carries 8,192 tokens, so each expert sees 256 rows; without it one
request takes the whole budget while three wait. That is also why shrinking the *global* budget was
counterproductive earlier while capping *per request* was not — one empirical finding and one hardware
mechanism turn out to be the same fact.

## What this does to the economic conclusions

Single-digit MFU means the throughput ceilings reported here are the software stack's, not the hardware's.
The right treatment is not simply to relabel dollars as lower bounds:

* **Absolute figures carry a configuration.** Every "$X per box-hour" is a statement about this model, this
  vLLM version, FP8, TP=2 × 2 replicas, this scheduler and this SLO. The engine version is an experimental
  variable, not a constant, and headline numbers get re-measured when it changes.
* **Relative conclusions survive.** Orderings, curve shapes and thresholds — shorter uncached input is
  worth more per box-second, the cache is flat to ~30% of the pool, affinity routing recovers about eight
  points — do not flip if throughput doubles.
* **Operating points do not survive.** The best `long_prefill_token_threshold`, the admission caps, the
  crossover load: each balances against current throughput and has to be re-derived after a stack change.
* **Never call an observed maximum a hardware ceiling.** Record it as a configuration ceiling naming model,
  engine version, precision, parallelism, replica count, scheduler settings and SLO.

## Memory budget, checked

20 KiB/token × 2,042,667 tokens = **38.96 GiB**, matching the reported pool. The 30 linear-attention layers'
recurrent state is **not** in that pool: vLLM allocates hybrid models' SSM state as a fixed per-sequence
buffer sized by `max_num_seqs`, not as token-paged blocks, so it must not be mixed into token arithmetic.
Per replica across 2 GPUs: 17.5 GB of weights per GPU, 19.5 GiB of KV per GPU, a few GB of activations,
CUDA graphs, NCCL buffers and state — about 42–44 GB against `gpu_memory_utilization=0.92`. Consistent.

Worth noting for portability: **hybrid attention is why KV is only 20 KiB/token.** A full-attention model
of the same size would be roughly four times that, so the cache-capacity findings' absolute numbers would
be a quarter.

## Which findings travel

| Finding | Class | Note |
| --- | --- | --- |
| Uncached work = unique suffix + shared prefix × (1 − hit) | **general** | The most portable statement here. Any engine with prefix reuse. |
| Cache survival is set by capacity, not elapsed time | **architectural family** | Follows from LRU plus a stable working set; expected of SGLang's RadixAttention and TRT-LLM block reuse too. Conditional on no TTL, no compaction, no prefix-hash change, no other tenants. |
| Eviction is all-or-nothing per conversation | **policy-specific, not necessary** | Each turn re-touches the whole prefix, equalising recency, so block-LRU treats a conversation as one unit. A leaf-first policy like RadixAttention should trim tails instead and give partial hits. **Falsifiable: the same sweep on SGLang should change shape.** |
| The KV usage gauge cannot predict eviction | **this engine's metric semantics** | But the lesson generalises: monitor hit rate and eviction directly; usage gauges usually exclude cached-idle blocks. |
| Step budget and per-request quantum are different knobs | **concept general, knobs specific** | Any continuous-batching engine has both plus an admission limit. "Priority does not help" and "V1 has no long-prefill count cap" are this version's. |
| Backfilling long work into slack under a per-request cap | **general** | Isomorphic to HPC backfill. Admit on the foreground's tail SLO, not on average utilisation. Thresholds are local. |
| Cache-key and routing-key must agree | **general** | True wherever the cache is replica-local. The eight-point recovery is local. |
| Shorter uncached input is worth more per box-second | **general, on two premises** | Needs (1) API price linear in tokens and (2) serving cost per token non-decreasing in context length. Direction survives faster GPUs. But this model's quadratic term is weak — 10 of 40 layers — so much of the gradient may come from the price side, and very short prompts can invert on fixed overhead. Best written as the hit-rate-zero special case of the row above. |
| MoE decode reads the expert union, not the active set | **architectural family** | All fine-grained MoE. |
| Prefill MFU is governed by rows per expert | **architectural family, and not the binding constraint here** | The mechanism is real; the sweep shows it is not what limits this box. |

## What is not done

* **TP=1 versus TP=2 per GPU**, the next discriminator: 35 GB of FP8 weights fit in 48 GB with a smaller
  pool, and if per-GPU throughput rises more than ~1.3x then the PCIe all-reduce is the constraint.
* **SM-active against DRAM-active during prefill.** Both low would mean the time goes to gaps — launches,
  synchronisation, communication — rather than to either roof. Attempted here and not captured; it is the
  cheapest remaining discriminator.
* ~~The engine's own MFU accounting~~ — done, and it moved the answer: 62.0 TFLOP/s per GPU rather than
  27.8, so 8.5–17.1% MFU. Scraping it needs the pod IPs, not the Service: a Service-level scrape answers
  from one replica of two and reported a flat zero from the one that had served nothing.
* **The same survival sweep on SGLang**, which is the falsifiable half of the all-or-nothing finding.
