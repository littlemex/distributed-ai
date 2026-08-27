# AgentX: the agentic workload, measured with someone else's instrument

Measured 2026-08-27 with [SemiAnalysis AgentX](https://github.com/SemiAnalysisAI/InferenceX) —
AIPerf's `inferencex-agentx-mvp` scenario replaying 393 anonymised Claude Code traces — against the box
(Qwen3.6-35B-A3B-FP8, g6e.12xlarge, $15.2174/h, vLLM 0.27.1, TP=2 x 2 replicas, 262k window).

**These are smoke arms and neither is canonical.** The scenario enforces a 900-second minimum profile;
both arms ran 300 seconds at concurrency 1 with one warmup request per lane and `--unsafe-override`,
collecting 47 and 65 requests. AgentX itself marks such runs invalid for submission. The absolute numbers here
are a first measurement, not a leaderboard entry, and the box is not a published AgentX platform, so
nothing below is commensurate with the numbers on their dashboard.

## Why this benchmark and not another

Two reasons, and the first is the corpus rather than the harness.

**It independently reproduces this project's own workload characterisation.** The corpus is 68,266 model
requests carrying 6,891,228,864 input tokens against 58,728,807 output tokens — **99.15% of all tokens
on the input side**. This project measured 99.5% on its own SWE-bench episodes and had no way to know
whether that was a property of agentic coding or of one scaffold. It is the former.

**It measures the thing this box's economics turn on.** AgentX exists to reward prefix caching: its
premise is a 95%+ cache hit rate across turns of the same conversation. The first arm was run with
caching off and written up as the architecture being incapable of it. **That was wrong, and finding out
is the most valuable thing this benchmark has done here** — see the correction below. The second arm has
it on.

The harness is used as-is rather than imitated. `instruments/agentx/run.sh` pins the InferenceX commit,
initialises their AIPerf submodule, installs it into an isolated interpreter for their stated reason —
AIPerf must never share site-packages with the server it measures — passes their `build_replay_cmd` flag
set verbatim, and runs their aggregator rather than a reimplementation of their statistics. Deviations
are written into `provenance.json` on every run.

## The correction: it was never a capability, it was a missing flag

The first arm's write-up said vLLM refuses prefix caching for this model's hybrid attention and called
that "the measurement, not a misconfiguration". Checking the engine rather than restating the assumption
found the opposite. vLLM 0.27.1, `engine/arg_utils.py:2598`:

```python
default_chunked_prefill = model_config.is_chunked_prefill_supported
# Hybrid models support prefix caching but keep it opt-in for now
# while the feature matures.
default_prefix_caching = (
    model_config.is_prefix_caching_supported and not model_config.is_hybrid
)
```

For this model `is_prefix_caching_supported` is `True` and `is_hybrid` is `True`, so the default is off
and the feature is **opt-in**. And `EngineArgs.enable_prefix_caching` defaults to `None`, meaning "take
the model's default" — so a run with no flag is a run with caching off. The serving chart rendered
`--no-enable-prefix-caching` for the false branch and **nothing at all** for the true branch, so setting
the overlay to true changed nothing, the engine kept reporting `False`, and that was published as an
architectural limit.

Three attempts to measure one flag: once with it explicitly off, once with it nominally on but never
passed, once actually on. The lesson is the same one this project has now learned three times in
different clothes — a value in a configuration file is a request, and the engine's own config line is
the fact. Both branches now render an explicit flag so the intent is always on the command line.

## What the box did, with caching off

| | |
| --- | --- |
| Input sequence length | p50 **42,638** / avg 55,038 / max 195,796 tokens |
| Output sequence length | p50 **137** / avg 335 tokens |
| Time to first token | p50 **6.93 s** / p90 13.37 s / max 28.57 s |
| Request latency | p50 11.50 s / p90 21.76 s / max 99.01 s |
| Inter-token latency | p50 13.95 ms (71.7 tokens/s/user) |
| Input token throughput | 7,839 tokens/s |
| Output token throughput | 47.7 tokens/s |
| Request throughput | 0.14 requests/s |
| **Theoretical prefix cache hit** | **94.42%** |
| Actual prefix cache hit | **0%** (`vllm:prefix_cache_hits` = 0, `vllm:prefix_cache_queries` = 0) |

A developer's turn on this box takes **seven seconds to start printing**, median, and thirteen at p90 —
with the cache off.

The engine's own counters, scraped per replica through AIPerf's `--server-metrics`, say what was *not*
the constraint: `vllm:num_preemptions` totalled 0, `vllm:num_requests_waiting` peaked at 0, and
`vllm:kv_cache_usage_perc` peaked at 14.9% on one replica and 7.6% on the other. No queueing, no
preemption, KV barely touched. **The box was limited by reading the same tokens again.**

Quantified: of the 2,586,787 prompt tokens it processed, 94.42% — **2,442,444 tokens** — were tokens a
prefix cache would have served for free. At 7,839 tokens a second that is **5.2 minutes of the
5.6-minute window**, or 93% of the box's time spent on work the API does not pay for.

`vllm:prefix_cache_queries` being zero rather than merely unmatched was the clue that should have been
followed at the time: the engine was not looking. That is what a disabled feature looks like, and it was
read as what an unsupported one looks like.

## With caching on: the same arm, one flag changed

Second arm, identical in every other respect — same corpus, same flags, 300 s at concurrency 1, 65
requests collected.

| | caching off | caching on | change |
| --- | --- | --- | --- |
| Time to first token, p50 | 6,932 ms | **603 ms** | **11.5x faster** |
| Time to first token, p90 | 13,369 ms | **3,905 ms** | 3.4x |
| Request latency, p50 | 11,500 ms | **2,250 ms** | 5.1x |
| Inter-token latency, p50 | 13.95 ms | 9.72 ms | 1.4x |
| Prompt tokens computed, per request | 55,038 | **9,654** | **5.7x fewer** |
| Cache read tokens | 0 | **3,543,936 / 4,171,465** | **84.96% hit** |
| Requests in the window | 47 | 65 | 1.38x |
| Input token throughput | 7,839 tok/s | 12,641 tok/s | 1.6x |
| Box cost per request | $0.0302 | **$0.0211** | 1.43x cheaper |

**84.96% actual against 94.14% theoretical is 90.2% of the available reuse captured.** The missing tenth
is routing rather than the engine: two replicas sit behind one Service, a conversation's later turns can
land on the replica that does not hold its prefix, and the live per-replica hit rates during the run were
**86.2% and 66.1%**. AIPerf ships `--use-dynamo-conv-aware-routing` for exactly this, and the ceiling
here is higher than what was measured.

Note that throughput improved far less than latency (1.38x against 11.5x), and that is not a
disappointment — at concurrency 1 the replay is latency-bound, waiting for each turn before issuing the
next. The 5.7x reduction in computed tokens shows up as time to first token, not as requests per second.
Seeing it as throughput needs a concurrency sweep, which is now the obvious next arm.

## Correctness first: a cache hit gives the same answer

vLLM keeps this opt-in "while the feature matures", and the reason it is hard is the reason it needed
checking before anything was built on the 11.5x: reusing a prefix on a hybrid model means restoring a
linear-attention layer's **recurrent state** at a block boundary, not just re-reading paged KV. A wrong
restore is silent — the request succeeds and the answer changes.

`benchctl/cache_equivalence.py` grows a conversation one turn at a time so every turn after the first is
a partial-prefix restore, sends each prompt twice at temperature 0, and compares the continuations
character by character. Bitwise determinism is not guaranteed even without caching, so the arm where both
calls miss is the control.

**22 of 22 cache-hit pairs identical, 24 of 24 pairs identical overall**, across prefixes of 2,000, 8,000
and 30,000 tokens and four turns each — including a turn with 35,904 of 36,493 prompt tokens served from
cache. Nothing to report, which is the result worth having.

The same run showed the latency effect on a single pair without any averaging: **3.49 s on the miss,
0.18 s on the hit.**

It also showed the routing loss directly, at concurrency 1. The cached-token count for consecutive
identical calls oscillated 35,904 → 9,504 → 35,904: a call that lands on the other replica finds only the
short common prefix. That is the two-replica split visible without any load at all.

## The price

| | per agentic request |
| --- | --- |
| Box, caching off | $0.0302 |
| Box, caching on | **$0.0211** |
| `claude-haiku-4-5`, ideal 94% cache | $0.0120 — the box is **1.76x more expensive** (was 3.04x) |
| `claude-haiku-4-5`, no cache at all | $0.0642 — the box is 3.0x cheaper |

The box's input price on this workload falls from $0.5393 to $0.3345 per Mtok. Still far worse than the
$0.0603 the short shapes reach, because these prompts are long and ten of forty layers cost quadratic
time in length — but the box is now within a factor of two of the cheapest API on the family this project
was built to serve, from a factor of three.

Two caveats, both against the box. The 94% is AgentX's *theoretical* hit rate; Anthropic's five-minute
TTL and 1.25x cache-write premium make the real API bill somewhat higher than that row, so the 1.76x
overstates the box's disadvantage a little. And the box figure assumes 100% utilisation, which the
arrival-rate work showed is the optimistic end.

## What this changes

* **The agentic family is back in contention.** It was excluded on the strength of a number that came
  from a flag being unset. At 1.76x the cheapest API with an ideal cache, and with the routing tenth
  still unclaimed, it is no longer obviously the wrong family for this box.
* **The published guidance built on "no caching" needs re-reading, not just this page.** The shape
  surface and the co-residency work were both measured with caching genuinely off, so their numbers are
  correct for the configuration they were taken under — but two of their conclusions leaned on caching
  being impossible, and both are now qualified in place.
* **The synthetic surface must salt its prompts before it is re-run.** Both advisors warned that
  identical padding could be served from the cache and inflate the box's side. At the time it could not
  be, which is why the warning was recorded and dismissed. Now it can, so any re-run needs a unique
  prefix per request or it will measure the cache instead of the box.
* **Preemption is now much more dangerous, and also much less likely.** V1 preempts by recompute; with a
  cache, a preempted long prompt can come back from cached blocks instead of from nothing — provided the
  blocks have not been evicted. That is a new failure mode to watch at high concurrency rather than a
  solved problem.
* **`--enable-prompt-tokens-details` earned its place.** It is what turned `cache_read_tokens` from
  "absent, cannot tell" into 3,543,936.

## What is still missing

* **A canonical run.** 900 seconds minimum, more warmup per lane, and a concurrency sweep. At
  concurrency 1 the effective concurrency was already 2.12 because a trace tree spawns subagents, so the
  low end is not what it looks like — and throughput, where caching should pay most, is unmeasured.
* **Conversation-affinity routing.** 86% and 66% on two replicas is a routing loss, and the fix is known.
* **The 1M-context corpus.** The harness selected the 256k-capped variant, right for a 262k window, but
  it means AgentX's hardest traces were excluded.
* **Whether caching survives KV pressure.** At concurrency 1 the pool peaked under 15%. Cached blocks
  compete with live sequences for the same 2.0M tokens, so the hit rate at real concurrency is a
  different measurement from the hit rate here.
