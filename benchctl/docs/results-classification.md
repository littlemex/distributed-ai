# Classification, first family measured

Measured 2026-08-27. Box: Qwen3.6-35B-A3B-FP8 on g6e.12xlarge (4x L40S, $15.2174/h), vLLM 0.27.1,
TP=2 x 2 replicas, 262k window, prefix caching declined by the engine. Baseline: `claude-haiku-4-5`
through the gateway, list price $1.00 / $5.00 per Mtok.

**The items are a public dataset, not held-out production traffic.** `p_i` is defined on the traffic the
box would actually serve, so nothing here admits anything. What it does is prove the path and produce the
first real `net_offload_value`.

## Quality: the two layers are indistinguishable

The first attempt used three classes and every miss on both layers was the neutral one, so the suite was
largely measuring whether a model can guess a three-star rating. Dropped to two classes:

| | box | haiku |
| --- | --- | --- |
| passed | 47/48 | 47/48 |
| paired: only baseline / only box | 0 / 0 | |
| difference | +0.0 pp, one-sided 80% lower bound +0.0 | |
| latency p50 per item | **0.17 s** | 1.56 s |
| prompt tokens per item (each layer's own count) | 183 | 298 |

Non-inferior at a two-point margin, with **zero discordant pairs** — the same 47 items right and the same
one wrong on both layers.

Two readings of that, and they point opposite ways depending on the question:

* **For admission, this is the answer you want.** The traffic in this family is easy enough that the
  cheaper layer is not worse, and the decision has no residual risk to price.
* **For ranking layers, the suite is now saturated and useless.** At 0.979 on both sides there is no
  resolution left: a real quality gap of a few points would be invisible. So this suite may gate this
  family and may not be used to compare models in general.

## Cost: the box only earns its keep when it is busy

Two request shapes, measured in-cluster at several concurrencies. `box_seconds_per_request` is the
objective's denominator, and it is a property of the batch — which is why it is measured here and not
inferred from the quality cell's one-request-at-a-time timings.

Short shape, the one the canary actually uses (about 240 input tokens, 8 output):

| In flight | Requests/hour | Box seconds/request | $/1k requests | TTFT p50 |
| --- | --- | --- | --- | --- |
| 1 | 24,199 | 0.149 | 0.629 | 0.12 s |
| 8 | 87,853 | 0.041 | 0.173 | 0.23 s |
| 16 | 139,779 | 0.026 | 0.109 | 0.24 s |
| 32 | 235,893 | 0.015 | 0.065 | 0.28 s |
| **64** | **264,194** | **0.014** | **0.058** | 0.56 s |

Long shape (about 2,300 input tokens, 16 output), for contrast:

| In flight | Requests/hour | $/1k requests | Read tok/s | TTFT p50 |
| --- | --- | --- | --- | --- |
| 1 | 15,342 | 0.992 | 8,233 | 0.22 s |
| **16** | **35,127** | **0.433** | 18,852 | 1.02 s |
| 64 | 35,281 | 0.431 | 18,934 | 3.59 s |

The long shape saturates at sixteen in flight and the short shape not until sixty-four, because prefill is
compute-bound and dominates the long one.

### The number the framing was built to produce

`net_offload_value` for this family, against haiku's own billed tokens for the same items:

| In flight | Box $/request | Saving/request | **API spend avoided per box-hour** | vs the box's own $15.22 |
| --- | --- | --- | --- | --- |
| 1 | 0.000629 | **−0.000291** | **−$7.04** | **loses money** |
| 8 | 0.000173 | +0.000165 | +$14.48 | 1.0x — break-even |
| 16 | 0.000109 | +0.000229 | +$32.04 | 2.1x |
| 32 | 0.000065 | +0.000274 | +$64.53 | 4.2x |
| 64 | 0.000058 | +0.000280 | **+$74.10** | **4.9x** |

**At one request in flight the box is worse than just paying haiku.** Break-even is around eight
concurrent. From sixteen up it earns, and full it avoids about $74 an hour of API spend while costing
$15.22 — nearly five times its own rate.

That is the whole case for the box stated in one table, and it is a statement about **occupancy**, not
about the model. The same hardware, the same weights and the same family lose money or make five times
their cost depending only on how many requests are in flight. Any admission rule for this family has to
carry a minimum concurrency with it, or it will be admitting work at a loss.

## Two accounting models, and where they agree

The token rates derived earlier ($0.236 input, $4.12 output per Mtok) predict $0.0575 per 1k requests for
this shape. The box-time measurement says $0.058 at sixty-four in flight and $0.629 at one. So the derived
rates are **the saturation limit, not the price** — they agree with reality only when the machine is full,
and overstate the box's advantage by up to eleven times when it is not. Quote them with the concurrency
they assume, or not at all.

## What is still missing

* Held-out production traffic. Everything above is a public dataset.
* A suite with resolution. This one is saturated; comparing layers needs harder items or a stricter output
  contract.
* ~~The long-input extraction family, which is where the money is~~ — **wrong, and measured wrong.** The
  saving per request does scale with input length, but the objective divides by box time and box time grows
  faster. This family's 300-token shape turns out to be near the best shape the box has; see
  `results-shape-surface.md`.
* Everything above was taken with `max_num_seqs=27`, which was binding. At 256 seats this family's shape
  reaches 265,792 requests/hour rather than 264,194, and the 60-token corner gains 33%.
* `sglang.benchmark.serving` as the perf instrument. The stand-in used here reports what it measures, but
  the real tool ships the datasets and the percentiles, and needs a node pool with disk requested for it.
