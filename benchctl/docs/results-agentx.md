# AgentX: the agentic workload, measured with someone else's instrument

Measured 2026-08-27 with [SemiAnalysis AgentX](https://github.com/SemiAnalysisAI/InferenceX) —
AIPerf's `inferencex-agentx-mvp` scenario replaying 393 anonymised Claude Code traces — against the box
(Qwen3.6-35B-A3B-FP8, g6e.12xlarge, $15.2174/h, vLLM 0.27.1, TP=2 x 2 replicas, 262k window).

**This is a smoke arm and is not canonical.** The scenario enforces a 900-second minimum profile; this
was 300 seconds at concurrency 1 with one warmup request per lane, run with `--unsafe-override`, and it
collected 47 requests. AgentX itself marks such a run invalid for submission. The absolute numbers here
are a first measurement, not a leaderboard entry, and the box is not a published AgentX platform, so
nothing below is commensurate with the numbers on their dashboard.

## Why this benchmark and not another

Two reasons, and the first is the corpus rather than the harness.

**It independently reproduces this project's own workload characterisation.** The corpus is 68,266 model
requests carrying 6,891,228,864 input tokens against 58,728,807 output tokens — **99.15% of all tokens
on the input side**. This project measured 99.5% on its own SWE-bench episodes and had no way to know
whether that was a property of agentic coding or of one scaffold. It is the former.

**It measures the thing this box is structurally worst at.** AgentX exists to reward prefix caching: its
premise is a 95%+ cache hit rate across turns of the same conversation. vLLM reports
`enable_prefix_caching=False` for this model's hybrid attention, so the box gets none of it. That is not
a misconfiguration to fix; it is the measurement.

The harness is used as-is rather than imitated. `instruments/agentx/run.sh` pins the InferenceX commit,
initialises their AIPerf submodule, installs it into an isolated interpreter for their stated reason —
AIPerf must never share site-packages with the server it measures — passes their `build_replay_cmd` flag
set verbatim, and runs their aggregator rather than a reimplementation of their statistics. Deviations
are written into `provenance.json` on every run.

## What the box did

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

A developer's turn on this box takes **seven seconds to start printing**, median, and thirteen at p90.

The engine's own counters, scraped per replica through AIPerf's `--server-metrics`, say what was *not*
the constraint: `vllm:num_preemptions` totalled 0, `vllm:num_requests_waiting` peaked at 0, and
`vllm:kv_cache_usage_perc` peaked at 14.9% on one replica and 7.6% on the other. No queueing, no
preemption, KV barely touched. **The box was limited by reading the same tokens again.**

Quantified: of the 2,586,787 prompt tokens it processed, 94.42% — **2,442,444 tokens** — were tokens a
prefix cache would have served for free. At 7,839 tokens a second that is **5.2 minutes of the
5.6-minute window**, or 93% of the box's time spent on work the API does not pay for.

`vllm:prefix_cache_queries` being zero rather than merely unmatched is worth noting: the engine is not
looking, so this is a capability that is absent rather than a cache that is missing.

## The price, and the one number it turns on

| | per agentic request |
| --- | --- |
| Box, at 100% utilisation | **$0.0302** |
| `claude-haiku-4-5`, with an ideal 94.42% cache | **$0.0099** — the box is **3.04x more expensive** |
| `claude-haiku-4-5`, with no cache at all | $0.0567 — the box is 1.88x cheaper |

The box's input price on this workload is **$0.5393 per Mtok**, derived from its measured 7,839
tokens/s, which is nine times worse than the $0.0603 the short-classification shapes reached — because
these prompts are long and ten of forty layers are full attention.

**The gap between the two API rows is 5.7x and it is entirely prompt caching.** On the family this
project was built to serve, the verdict inverts on that one feature: with caching the API wins by three
times, without it the box wins by nearly two. The API has it and this model structurally cannot.

Two caveats on the comparison, both of which move it against the box's favour rather than for it. The
94.42% is AgentX's *theoretical* hit rate, an ideal cache with no TTL; Anthropic's five-minute window and
1.25x cache-write premium make the real API bill somewhat higher than the ideal-cache row, so the true
3.04x is an overstatement of the box's disadvantage but not by much. And the box figure assumes 100%
utilisation, which the earlier arrival-rate work showed is the optimistic end of a wide range.

## What this changes

* **The agentic family is not a candidate for this box, and now there is a public number for why.** The
  earlier SWE-bench work reached the same conclusion from a 94.9% re-read estimate on 22 episodes; this
  is 393 traces, someone else's harness, and the engine's own counters agreeing.
* **The decisive experiment is a model swap, not a tuning pass.** Everything above is one architecture's
  cost. Running the identical AgentX arm against a full-attention model on the same box, where vLLM's
  prefix caching does work, would price the 94.42% directly — same hardware, same traces, same
  instrument, one variable. That is the strongest experiment available here and it is not done.
* **`--enable-prompt-tokens-details` is now on by default in the chart.** AIPerf printed that it could
  not find `usage.prompt_tokens_details.cached_tokens` and therefore could not distinguish "no cache
  reporting" from "no cache". On this box the answer is zero either way, which is exactly why the flag
  matters: it makes the zero a measurement rather than an absence.
* **The stand-in stays for synthetic shapes.** `perf_cell.py` said from the start that it was a
  placeholder for a real instrument. AgentX is that instrument for the agentic family. It does not
  replace the shape surface, which needs prompts of a controlled length that no trace corpus provides.

## What is still missing

* **A canonical run.** 900 seconds minimum, more warmup per lane, and a concurrency sweep rather than
  one point. At concurrency 1 the effective concurrency was already 2.12, because a trace tree spawns
  subagents, so the sweep's low end is not what it looks like.
* **The full-attention A/B**, above.
* **The 1M-context corpus.** The harness selected the 256k-capped variant automatically, which is right
  for a 262k window, but it means the hardest traces in AgentX were excluded from this run.
* **KV headroom at real concurrency.** KV peaked under 15% at concurrency 1. With average prompts of
  55,038 tokens at 20 KiB per token, the 2.0M-token pool holds roughly 36 of them, so the sweep will run
  into KV long before it runs into compute — and with prefix caching off, a preemption means recomputing
  the whole prompt.
