# How much reuse the box can hold, and why the obvious gauge cannot see it

Measured 2026-08-28. Box: Qwen3.6-35B-A3B-FP8, TP=2 x 2 replicas, `enable_prefix_caching=True`,
`max_num_seqs=128`, `long_prefill_token_threshold=2048`, KV pool **2,042,667 tokens per replica** (both
engines report that figure independently, and the engine's own "Maximum concurrency for 262,144 tokens per
request: 7.79x" line confirms it is per-engine, not per-box). Traffic goes through the conversation-affinity
router, so a conversation always reaches the replica holding its prefix.

Prefix caching turned the agentic family from a 3.04x loss against the cheapest API into a 1.76x one, and
the question that follows is how much of that survives real load. A cache hit is not a property of a
request; it is the probability that a conversation's blocks are still resident when its next turn arrives.
So the quantity is a survival curve, and `benchctl/prefix_survival.py` measures it by walking a ring of C
conversations, each with its own unique prefix, and recording the engine's own
`usage.prompt_tokens_details.cached_tokens` on every turn.

## The curve, and the cliff in it

`prompt_tokens` is measured rather than assumed, and that mattered: the filler tokenises to about seven
tokens a word, so a requested 60,000 came out as **103,406** actual tokens per turn. The nominal column is
kept because the gap between the two is the reason a first reading of this experiment was wrong.

| Conversations | Nominal | **Actual resident** | Per replica | Share of pool | Cached, mean | full / partial / miss | Gap p50 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2 | 120,000 | 206,811 | 103k | 5% | **99.1%** | 6 / 0 / 0 | 0.4 s |
| 6 | 360,000 | 620,637 | 310k | 15% | **99.1%** | 15 / 3 / 0 | 0.8 s |
| 12 | 720,000 | 1,240,980 | 620k | **30%** | **99.1%** | 30 / 6 / 0 | 1.4 s |
| 20 | 1,200,000 | 2,068,040 | 1.03M | **51%** | **71.0%** | 37 / 6 / **17** | 70.5 s |
| 32 | 1,920,000 | 3,309,312 | 1.65M | **81%** | **0.0%** | 0 / 0 / **96** | 218.1 s |
| 48 | 2,880,000 | 4,963,968 | 2.48M | 121% | **0.0%** | 0 / 0 / **144** | 322.1 s |

**Below about 30% of the per-replica pool the cache is essentially perfect; at 51% it is bimodal; by 81% it
is gone.** The residual 0.9% at the top of the curve is the unique suffix plus the last partial block,
which is block granularity rather than a miss.

The shape at the knee is the interesting part. At C=20 the *median* stayed at 99.0% while the mean fell to
71.0%, with seventeen turns at exactly zero. So this is not every conversation losing its tail — it is
**whole conversations losing everything while their neighbours keep everything**. Eviction is LRU over
blocks, and a conversation's blocks are contiguous in recency, so they go together. An advisor predicted a
gradual degradation from partial hits for exactly the opposite reason; the measurement says all-or-nothing
per conversation.

## It is capacity, not age — and that had to be checked

C sets two things at once in this design: the working set *and* how long before a conversation comes round
again. The gap grew from 1.4 s to 322 s across the sweep, so a collapse at high C could have been either.

Control: C=12, which sits at 99.1% with a 1.4 s gap, re-run with an explicit sleep injected. Median gap
rose to **50.0 s — 36 times longer — and the hit rate was 99.1%, unchanged.** Age does not degrade the
cache. What does is how much other content is resident.

## The gauge that cannot see this

While the cache was collapsing, `vllm:kv_cache_usage_perc` peaked at **21.0% and 31.4%** on the two
replicas. Reading that first led to the conclusion that the pool was 70% free and capacity therefore
could not be the cause — which was wrong.

**That gauge counts the KV of running sequences. It does not count cached-but-idle blocks.** So the metric
that looks like it should predict prefix-cache eviction cannot, and a monitoring dashboard built on it
would show plenty of headroom at the exact moment the cache stops working. What does predict it is
arithmetic on resident tokens: conversations in flight times their prompt length, against the per-replica
pool.

The first-order model an advisor proposed — horizon ≈ pool capacity divided by the new-KV write rate — is
therefore the wrong shape for this engine. There is no horizon in seconds to compute, because there is no
age term. The right model is a residency budget.

## What it means for the agentic family

The corpus's main turns have a median input of **158,944 tokens** (the 42,638 that AgentX reports at p50
includes the much shorter subagent requests). Against a 1.04M-token knee per replica, that is:

* **about 6 conversations per replica, 13 across the box**, before the cache starts failing;
* **about 4 per replica, 8 across the box**, to stay in the flat region with margin.

That is the real capacity of the agentic family on this hardware, and it is small. The 1.76x figure against
the cheapest API was measured at one trajectory lane, comfortably inside the flat region — so it is the
box's *best* case, and the admission rule needs a hard cap on concurrent conversations to stay there.

It also sharpens the earlier co-residency work. `results-coresidency.md` capped resident long requests to
protect short-family latency; this caps resident *conversations* to protect the cache. They are different
limits with different reasons, and the tighter one binds.

## What is still open

* **The cost answer.** $/request has not moved from $0.0211 because every arm so far has been
  latency-bound rather than throughput-bound. What decides admission is dollars per success at the maximum
  sustained rate that holds an SLO, and now there is a second constraint on that rate: it must also keep
  resident conversations under the knee. Both advisors independently framed the comparison the same way,
  and one added the part that is easy to fudge — the box's figure must use realistic utilisation, not 100%.
* **The API's own cache is not free either.** Providers expire cached prefixes on their own schedule, and
  a cache-write premium applies. The comparison has to use the API's *billed* cached ratio at realistic
  pacing rather than an ideal-cache calculation, and the corpus's gap distribution (p90 at 259.7 s, p99 at
  6,391 s) says a meaningful share of turns would miss a short provider TTL.
* **Whether the knee moves with prefix length.** Every cell here used a ~103k prefix. Whether the limit is
  really a token budget or partly a per-conversation block-accounting cost is untested, and the real
  distribution is wide.
* **The grid.** Shared prefix against unique suffix, with this residency budget as a known constraint
  rather than a discovery. Both advisors put it after this measurement, which was right.
