# Prefix reuse is the box's whole advantage, and it needs 71% of it to hold

Measured 2026-08-29 by `benchctl/prefix_reuse_cost.py`. Box: Qwen3.6-35B-A3B-FP8, TP=2 x 2 replicas,
$15.2174/h, prefix caching on. APIs through the gateway, priced from `specs/model-rates.json`. Traffic:
conversations built to AgentX's measured shape — a 12,000-token shared preamble standing in for a system prompt
and tool definitions, a per-conversation history that grows by ~1,500 tokens a turn, six turns each, and a
bounded reply. Both sides measured. **No quality claim on this page**: it is a bill.

## Why this run exists

The pricing correction left one question live and it is the one the project turns on. `gemma-4`, at AWS's
published $0.14 / $0.40, is the cheapest layer in both families measured so far — cheaper than the box on
OCRBench ($0.050 against $0.117 per thousand items) and on summarisation ($1.548 against $4.505). If that held
everywhere, "route it to the box" would almost never be the right answer, and this project's premise would be
in trouble.

But `gemma-4` **does not cache**, in any request shape, at any length. And the box's own prefix cache does, at
a measured $0.0188 per Mtok against its fresh $0.2295 — 8.2%. So the prediction was that prefix reuse is
exactly and only where the box beats the cheap tier. That is testable, and this is the test.

## The result

| layer | prompt tok / req | out tok / req | cached | in:out | $/1k requests | latency p50 |
| --- | --- | --- | --- | --- | --- | --- |
| **box-qwen36-tp2x2** | 13,338 | 213 | **82.5%** | 63:1 | **$1.636** | **0.47 s** |
| api-gemma-4 | 13,362 | 690 | 3.1% | 19:1 | $2.147 | 10.76 s |

**The box is 1.31x cheaper on identical traffic, and 23x faster at the median.** The prediction holds, and the
mechanism is the one predicted: the box turns 82.5% of its prompt tokens into cache reads at 8% of the fresh
rate, and `gemma-4` pays its flat rate on essentially all of them.

Two corrections to that headline, both of which narrow it.

**`gemma-4` was more verbose, and verbosity is not a rate.** It wrote 690 output tokens against the box's 213
for the same instruction. Normalising it to the box's output length, `gemma-4` costs $1.956 per thousand and the
box is **1.20x cheaper** rather than 1.31x. That is the number to quote for a rate comparison; the 1.31x
includes a model behaviour that a different prompt might change.

**The first version of this run said 2.01x, and it was wrong.** It capped output at 96 tokens and asked for one
sentence, which made the traffic 1,326:1 input-to-output. AgentX's corpus is 117:1. Since the box's output rate
is $4.12 per Mtok against `gemma-4`'s $0.40 — **ten times worse** — squeezing output out of the shape hands the
box an advantage the real traffic does not give it. Prefill fidelity is not shape fidelity.

## The break-even, which is the actual routing rule

The box's advantage is entirely on the prefill side, so it is bounded by how much of the traffic is prefill.
The cache hit rate the box needs on prompt tokens to match `gemma-4`, as a function of the traffic's
input-to-output ratio:

| input:output | hit rate the box needs | where that ratio comes from |
| --- | --- | --- |
| 19:1 | **100%** — cannot win | `gemma-4`'s own verbosity on this prompt |
| 63:1 | **71.4%** | the box's own, as measured here |
| 117:1 | 58.8% | AgentX's 393-trace corpus |
| 1326:1 | 45.5% | this run's first, unfaithful version |

At the measured shape the box needs **71.4%** and achieves **82.5%**, so the margin is real and thin. At
AgentX's true 117:1 the same hit rate would make it **1.56x** cheaper. And at 19:1 there is no hit rate that
saves it: a decode-heavy family goes to `gemma-4` however well the cache works.

That is the rule this project was looking for, and it is narrower than "the box is cheap":

- **Prefill-heavy traffic with a reused prefix → the box.** It is the only cheap layer here with a working
  cache, and 82.5% of a 12k-token shared preamble is worth more than a tenth-of-a-cent input rate.
- **Single-shot traffic → `gemma-4`.** Zero reuse means the box pays its fresh $0.236 against `gemma-4`'s
  $0.14, and loses on output ten to one on top. That is exactly why it loses on OCRBench and summarisation.
- **Decode-heavy traffic → `gemma-4`**, regardless of reuse.

## The premium layers, for completeness

From the first run, at the same traffic (six conversations, one-sentence replies):

| layer | cached, after turn 1 | $/1k requests |
| --- | --- | --- |
| api-haiku-4-5 | **0.0%** | $13.434 |
| api-sonnet-5 | **90.6%** | $18.116 |

This is the cache story in two rows. `claude-haiku-4-5` is the cheap Claude layer and gets no discount at all,
which is what flips the agentic family's sign — `results-agentx.md` priced it at an assumed 94%. `claude-sonnet-5`
gets almost all of the reuse there is and is still the most expensive layer measured, because a 90% discount on
a $3.00 rate does not reach a $0.14 one.

`claude-sonnet-5` completed 30 of 36 requests. The six failures are its documented habit of spending the output
budget before it speaks, at a 96-token cap; its cost per request is over the requests it finished.

## What this does not say

**Nothing about quality.** The traffic is synthetic, built to a token shape. The families that measure quality
measure it on real items.

**The box's cost is at 100% utilisation**, as everywhere in this project. At half that occupancy the same work
costs twice as much, and the 71.4% break-even becomes unreachable. The API rates carry no equivalent
assumption, so this comparison is at the box's optimistic end and the margin above is the best case.

**One box configuration and one gateway.** `gemma-4`'s 3.1% is measured on this gateway, which returns no
cached tokens for it in any shape probed; the 3.1% here is small enough to be block-boundary noise on a shared
preamble rather than a working cache.

**The hit rate is not a constant.** 82.5% is what six conversations against one replica pair achieved with the
conversation-affinity router. `results-prefix-survival.md` measures what happens to it under load, and the
answer is a cliff: past about half the KV pool the hit rate goes to zero. A family that needs 71.4% to be worth
routing to the box needs to know how close it is running to that cliff.
