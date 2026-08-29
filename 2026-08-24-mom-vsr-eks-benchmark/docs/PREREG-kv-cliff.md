# Pre-registration: where the prefix cache starts evicting, and the alarm that follows

**Written 2026-08-30, before the sweep.** `benchctl/docs/results-arrival-sweep.md` found that the second
constraint it expected — the cache collapsing under load — never appeared, and that hit rate *rose* with
load from 88% to 94%. It closed with the statement that the cliff is a function of **resident tokens**
rather than of arrival rate, and that the alarm point was never established. This fixes how it is.

## The prediction, from the engine's own configuration

The box reports, per replica:

- `kv_cache_size_tokens = 2042667`
- `num_gpu_blocks = 1987`, `block_size = 1056` (1987 × 1056 = 2,098,272, so the two agree)
- `kv_cache_max_concurrency = 7.79` at `max_model_len = 262144`

So one replica holds about **2.04M tokens** of KV. With the 12,000-token shared preamble the arrival
sweep used, that is **170 distinct prefixes resident per replica** before anything has to be evicted.

**The prediction, stated before the measurement: the hit rate holds while distinct resident tokens stay
under about 2.04M per replica, and falls once they exceed it — with the fall driven by how many distinct
prefixes are in flight, not by how fast requests arrive.** If the fall happens well before 2.04M, the
usable capacity is smaller than the engine claims and the reason has to be found. If it happens well
after, something is sharing blocks that this arithmetic does not model.

## The design

- **One replica, addressed by pod IP.** The Service round-robins across two, so a repeat request has only
  a 50% chance of reaching the replica that cached it — which is the 82.5% against 88.4% affinity gap this
  project already measured. Eviction is a property of the engine, so the router is removed rather than
  measured again.
- **A sweep in distinct prefixes**, each 12,000 tokens, each sent twice so a hit is possible: enough
  distinct prefixes to put resident tokens at roughly 25%, 50%, 100%, 150% and 200% of the 2.04M figure.
- **Read from the engine, not inferred**: `prefix_cache_hits_total` and `prefix_cache_queries_total`
  differenced per phase, alongside `kv_cache_usage_perc`.

## The readings, fixed now

1. **Hit rate per phase against predicted occupancy.** The number to report is where it breaks, in units
   of resident tokens and as a fraction of `kv_cache_size_tokens`.
2. **Whether `kv_cache_usage_perc` is usable as the alarm.** It is the only occupancy figure the engine
   exposes, so the question is whether it moves before the hit rate does. **A gauge that rises only after
   the cache is already thrashing is not an alarm**, and if that is what it does, the alarm has to be
   built from distinct resident tokens computed by the caller instead.
3. **The operational number**: the largest number of distinct concurrent prefixes of a given size that
   keeps the hit rate within a stated margin of its uncontended value.

## What this does not claim

This is a capacity property of one deployment at one preamble size. It says nothing about the agentic
result, which is settled against self-hosting for that traffic on other grounds. It matters for the
traffic family where the box does win — prefill-dominated with prefix reuse — and it is measured because
an operator of that family needs an alarm, not because it changes any conclusion already reported.


---

# Outcome: the prediction was wrong by about an order of magnitude, and the sweep was stopped

**Stopped 2026-08-30, deliberately and short of the third reading.** What was measured contradicts the
prediction badly enough to be worth recording, and the remaining question turned out to be a property of
one checkpoint rather than of routing, which is not what this project is for.

**What the prediction said:** the hit rate holds while resident tokens stay under `kv_cache_size_tokens`
of 2,042,667 per replica, i.e. about 170 distinct 12,000-token prefixes.

**What happened**, against one replica addressed by pod IP, at a fixed prompt size of about 4,525 tokens:

| distinct prefixes written between populate and reuse | tokens written | % of advertised KV | cached share on reuse |
|---|---|---|---|
| 32 | 149,292 | 7.3% | **93.4%** |
| 64 | 294,190 | 14.4% | **0.0%** |

And with 19,779-token prompts the reuse hit was already 0.0% at 40 distinct prefixes — 791,160 tokens, or
38.7% of the advertised figure. Two calls back to back hit 9,504 of 9,916 tokens (95.8%), so the cache
works; what fails is surviving intervening traffic.

**So the reusable prefix cache on this deployment is somewhere between 7% and 14% of the capacity the
engine advertises**, and the arithmetic in the prediction — resident tokens against
`kv_cache_size_tokens` — is not the right model of it.

**The second reading is settled, and it is a negative:** `kv_cache_usage_perc` read 0.00% throughout,
including immediately after writing 791,160 tokens of distinct prefixes. It reflects blocks held by
*running* requests, not blocks retained for reuse. **It cannot be used as a cache-occupancy alarm.** An
alarm has to be computed by the caller from distinct resident prefixes it has sent.

**The third reading — whether the bound is in tokens or in resident prefixes — was not established, and
the sweep was stopped rather than finished.** The reason is scope: separating those two would characterise
the block and SSM-state accounting of one hybrid checkpoint, and this project's conclusions have to hold
for an arbitrary tier. What generalises is the warning and the method, not the number:

- **Advertised cache capacity is not reusable capacity**, and the gap here is nearly an order of magnitude.
- **The engine's own occupancy gauge may not be an alarm**, so a router that depends on cache economics has
  to track distinct resident prefixes itself.
- The way to find a tier's real reusable capacity is the two-line experiment above: populate, interpose a
  measured number of tokens, re-send, read `cached_tokens` from the response. It costs minutes and it is
  worth running for **any** tier whose economics depend on prefix reuse — which, on this deployment, means
  any self-hosted tier, since cached input costs 8.2% of fresh.
