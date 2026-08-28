# Prefix reuse is the box's whole advantage, and 71% of it is the smaller of two conditions

> **Superseded in part by `results-arrival-sweep.md`.** The break-even hit rate below is correct and the box
> clears it. What this page got wrong is the framing: it treated eviction as the binding constraint, and the
> arrival sweep shows the binding constraint is volume — the box needs about 8,000 prefix-reusing requests an
> hour before it is cheaper than `gemma-4` at all, priced without the occupancy assumption every number here
> carries.

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

**Read that at one significant figure, and read the next section before acting on it.** Six conversations
against one replica pair with nothing else running is the flat top of this box's own cache-survival curve, and
the break-even below is close enough to what the pool holds under contention that the margin may not survive
being busy. Everything here is measured at the box's best corner.

Two corrections to that headline, both of which narrow it.

**`gemma-4` was more verbose, and verbosity is not a rate.** It wrote 690 output tokens against the box's 213
for the same instruction. Normalising it to the box's output length, `gemma-4` costs $1.956 per thousand and the
box is **1.20x cheaper** rather than 1.31x. That is the number to quote for a rate comparison; the 1.31x
includes a model behaviour that a different prompt might change.

**The first version of this run said 2.01x, and it was wrong.** It capped output at 96 tokens and asked for one
sentence, which made the traffic 1,326:1 input-to-output. AgentX's corpus is 117:1. Since the box's output rate
is $4.12 per Mtok against `gemma-4`'s $0.40 — **ten times worse** — squeezing output out of the shape hands the
box an advantage the real traffic does not give it. Prefill fidelity is not shape fidelity.

## Is gemma-4 a strawman? No, and it is worth showing why

`gemma-4` is the one API layer here that cannot cache, so comparing the box's cached rate against its flat rate
invites the objection that the box is being measured against the API's worst representative on exactly the
traffic that suits the box. The gateway has layers that reach 99.7% on this shape. The objection is answerable
from the sourced rates without sending anything — the effective price of a prompt token at each layer's own
measured hit rate:

| layer | hit rate | fresh | cached | **effective $/Mtok of prompt** | output |
| --- | --- | --- | --- | --- | --- |
| **box-qwen36-tp2x2** | 82.5% | $0.236 | $0.019 | **$0.0568** | $4.12 |
| api-gemma-4 | 3.1% | $0.140 | none published | $0.1400 | $0.40 |
| api-gpt-5.6-terra | 99.7% | $2.200 | $0.220 | $0.2259 | $13.20 |
| api-sonnet-5 | 99.8% | $3.000 | $0.300 | $0.3054 | $15.00 |
| api-gpt-5.6-sol | 99.7% | $4.400 | $0.440 | $0.4519 | $22.00 |
| api-haiku-4-5 | 0.0% | $1.000 | $0.100 | $1.0000 | $5.00 |
| api-opus-5 | 99.8% | $15.000 | $1.500 | $1.5270 | $75.00 |

**No layer's cached rate reaches the box's, and `gemma-4` is still the cheapest API even against layers running
at 99.8%** — because a cache read at a tenth of $4.40 is three times `gemma-4`'s full $0.14. So `gemma-4` is the
correct comparator rather than a convenient one, and the box's prefill advantage is structural rather than an
artefact of who it was compared against. At the measured shape the whole roster comes out: box $1.635, gemma-4
$1.953, gpt-5.6-terra $5.825, sonnet-5 $7.268, gpt-5.6-sol $10.713, haiku-4-5 $14.403, opus-5 $36.342 per
thousand requests.

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

### The margin is thinner than it looks, because the two requirements fight each other

The box is cheap only if it is busy — its rate is an hourly cost divided by throughput — and it is cheap only if
its cache hits. Those pull in opposite directions, because occupancy comes from concurrent conversations and
concurrent conversations evict each other's prefixes. Putting the break-even on the same axis as
`results-prefix-survival.md`'s measured hit rates:

| box occupancy | hit rate needed at 63:1 | at 117:1 | what the pool holds |
| --- | --- | --- | --- |
| 100% | 71.4% | 58.8% | 99% up to 12 conversations, 71% at 20, **0% at 32** |
| 75% | 88.2% | 75.3% | |
| 50% | **never** | 91.9% | |
| 25% | **never** | **never** | |

At 63:1 the box needs 71.4% at full occupancy, and the pool delivers 71.0% once 20 conversations are competing,
so this looked like a vice with the winning region squeezed to nothing between the two jaws.

**That sweep has now been run and the second jaw does not close** — see `results-arrival-sweep.md`. The hit rate
*rises* with load rather than collapsing, 88.4% at one request in flight to 94.3% at thirty-four, because more
traffic against a shared preamble means the preamble is more often already resident. The survival experiment's
cliff is real but it is a function of resident *tokens*, and its prefixes were 60,000 where these are 13,000, so
eviction never starts here.

What the sweep found instead is a harder threshold in the other direction. Priced with no occupancy assumption
at all — an hourly rate over what actually completed — the box needs about **8,000 prefix-reusing requests an
hour** before it is cheaper than `gemma-4` at all, and it is 25x more expensive at 313. Above the threshold it
improves monotonically to 3.0x cheaper. So the box's constraint is volume, not eviction, and the "thin margin"
framing this section originally carried was wrong in both directions: there is nothing thin about 3.0x, and
nothing cheap about the box below the threshold.

The 1.20x above should be read as the figure at roughly the crossing point, because the published token rates it
uses embed the occupancy this project had been assuming. The sweep supersedes it.

### As a principle, and as something a router could actually evaluate

The principle is narrower than "the box is cheap":

- **Prefill-heavy traffic with a reused prefix → the box.** It is the only layer here whose cached rate is an
  order of magnitude below every API's, and 82.5% of a 12k-token shared preamble is worth more than a
  tenth-of-a-cent input rate.
- **Single-shot traffic → `gemma-4`.** Zero reuse means the box pays its fresh $0.236 against `gemma-4`'s
  $0.14, and loses on output ten to one on top. That is exactly why it loses on OCRBench and summarisation.
- **Decode-heavy traffic → `gemma-4`**, regardless of reuse.

But "prefill-heavy with reuse" is a statement about a token shape, and a router cannot evaluate it: reuse is a
claim about the future. An advisor's reframing is the one worth adopting, because it turns every term into
something knowable when the request arrives — **reuse is a property of a session, and sessions are identifiable**:

- **Turn 2 or later of a session whose prefix is already resident on the box → the box.** No forecasting: the
  prefix is known to be there.
- **Admit a new session to the box only while pool occupancy is below the cliff** — under half, on this box's
  measured curve. This is admission control, and it is what the survival experiment is *for* rather than a
  caveat attached to it.
- **Turn 1, single-shot, and anything refused admission → the API.**

That last line has a consequence the shape-based rule got wrong. Traffic that overflows the box is by definition
prefix-reusing traffic, and `gemma-4` is the worst API layer for it on quality-per-dollar terms while being the
cheapest on price — so overflow is exactly where the choice between `gemma-4` and a caching premium layer needs
its own answer, and this run does not have one.

None of that is measured yet. It is a design, and the sweep in the section above is what would test it.

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

**The box's cost is at 100% utilisation**, as everywhere in this project, and the table above is what that
assumption is worth: at half occupancy the 71.4% break-even is unreachable at any hit rate. The API rates carry
no equivalent assumption. Four significant figures on $1.636 are not meaningful against a denominator that could
move it two to five times; one is.

**The 8.2% cached-token rate is a saturation figure.** It was fitted at 16 requests in flight, so it is the
incremental cost of a cached token on a machine that other traffic is already filling. On a quiet machine the
average cost of every token rises together, which is the same assumption as the paragraph above and not an
independent one.

**The latency comparison is not like-for-like on load.** Both figures are full-completion latency at
concurrency 1 from the same client, but the box was otherwise idle while the API is a shared service under
whatever load it had. The survival experiment measures what the box's own gap does under contention: from 1.4 s
to 218 s across the same occupancy range as the table above.

**One box configuration and one gateway.** `gemma-4`'s 3.1% is measured on this gateway, which returns no
cached tokens for it in any shape probed; the 3.1% here is small enough to be block-boundary noise on a shared
preamble rather than a working cache.

**The hit rate is not a constant, and this one is the no-affinity figure.** 82.5% is what six conversations
against one replica pair achieved through the **plain Service**, not through the conversation-affinity router:
that router pins pod IPs, the replicas had been rescheduled, and it had been timing out for two days without
failing visibly. `results-agentx.md`'s A/B puts affinity at about 7.6 points on top, so the box's side of the
break-even is probably better than measured here — and without affinity a session's turns alternate replicas,
so every prefix is cached on *both*, which doubles the KV a session occupies and brings the cliff forward.
Both of those are reasons to re-measure on the restored path rather than to adjust the number here. `results-prefix-survival.md` measures what happens to it under load, and the
answer is a cliff: past about half the KV pool the hit rate goes to zero. A family that needs 71.4% to be worth
routing to the box needs to know how close it is running to that cliff.
