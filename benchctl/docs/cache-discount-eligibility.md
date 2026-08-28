# The cache discount, measured: which layers get one, for what, and what it does to the agentic verdict

Measured 2026-08-28 through the gateway, by `scripts/probe_cache_eligibility.py` and the two-arm run in
`specs/runs/cache-ablation-v1.yaml`. Nothing here rests on a published policy: every number is the provider's
own cached-token count on a request this harness sent.

The discount is the largest single term in this project's arithmetic and it had never been measured per layer.
It should have been. It is not uniform, it is not what "the API caches and the box does not" describes, and
one documented conclusion rests on a hit rate this gateway does not deliver.

## The distinction that decides everything: shared prefix, or identical request

The first version of this page reported that `claude-sonnet-5` and `claude-opus-5` cache at 99.9% and drew
routing conclusions from it. The probe behind that number sent **the same request twice**, which cannot tell
two very different capabilities apart:

* **Identical-request caching** — the whole request repeats, byte for byte. Nearly useless: traffic that
  repeats a request identically should cache the *answer* and not pay for a cached prefill at all.
* **Shared-prefix caching** — many requests share a long preamble and differ after it. This is what agentic
  traffic, few-shot prompting and system prompts actually look like, and it is the only kind that routes
  anything.

Sending one preamble with three different questions after it separates them, and they come apart completely:

| layer | identical request repeated | **shared prefix, different tail** |
| --- | --- | --- |
| gpt-5.6-sol | 99.9% | **99.9%** at 3.5k tokens |
| gpt-5.6-terra | 99.9% | **99.9%** at 3.5k tokens |
| gpt-5.5 | 97.3% | **0%** at 3.5k, **97.8%** at 15k |
| claude-sonnet-5 | 100.0% | **0%** at 5.6k |
| claude-opus-5 | 100.0% | **0%** at 5.6k and at 24k |
| claude-haiku-4-5 | **0%** at 3.5k and 15k | **0%** |
| gemma-4 | **0%** at 3.5k and 15k | **0%** |
| the box (vLLM prefix caching) | — | **72.5%**, measured on a real run below |

**On this gateway, no Claude model gets a shared-prefix discount.** `claude-sonnet-5` and `claude-opus-5`
cache only a byte-identical repeat. `claude-haiku-4-5` does not cache even that, at any length tried, asked
or unasked, through either route the gateway offers. The GPT models do get a genuine shared-prefix discount,
from about 1k tokens for `gpt-5.6-sol` and somewhere between 3.5k and 15k for `gpt-5.5`. And the box's own
prefix cache works, which is the capability the APIs were assumed to have and mostly do not.

A discount also cannot be *requested*: every layer that caches does so automatically with no `cache_control`
breakpoint, and every layer that does not stays at zero when given one. So this harness is not leaving
anything on the table by never sending one, which is what it looked like when the question was first asked.
The gateway's Anthropic `/v1/messages` route is worse than useless for it — it mangles content parts, billing
9 input tokens for a 2,700-token request after dropping the preamble.

**Read every row as the gateway's behaviour, not the provider's.** Anthropic's own API does support
shared-prefix caching with an explicit breakpoint. What is measured here is what arrives when this project
sends a request, which is what its cost ledger has to be right about.

## What this does to the agentic verdict

`results-agentx.md` prices the agentic family like this:

| | per agentic request |
| --- | --- |
| Box, caching on | $0.0211 |
| `claude-haiku-4-5`, **ideal 94% cache** | $0.0120 — the box is 1.76x more expensive |
| `claude-haiku-4-5`, no cache at all | $0.0642 — the box is 3.0x cheaper |

The 94% is AgentX's theoretical hit rate, and the page says so. What was not known when that table was
written is that **`claude-haiku-4-5` returns zero cached tokens on this gateway under every condition probed**
— identical repeats, shared prefixes, 3.5k tokens and 15k, with and without a breakpoint, on both routes. So
the 1.76x row is a hypothetical, and the row that describes measured gateway behaviour is the one below it:
**the box is 3.0x cheaper on agentic traffic.**

That is a sign flip on the family this project was built to serve, and it favours the box, so the residual
uncertainty belongs next to it:

* A gateway could apply a discount in billing without reporting it in `usage`. If so this harness cannot see
  it and neither ledger is right — but then the 94% row is unverifiable rather than correct.
* The agentic runs went through the same `/v1/chat/completions` path probed here, so the paths agree, but the
  agent harness builds longer and more varied prompts than these probes and something in that shape could
  behave differently.
* The 3.0x row still assumes the box at 100% utilisation, which the arrival-rate work showed is the
  optimistic end. That caveat was always on it and still is.

The claim to make is therefore narrow and conditional: **against the cheapest API on this gateway as it
actually behaves, the box is cheaper on agentic traffic, not more expensive.** Confirming it properly means
re-running the agentic comparison with the API's cached-token count recorded per request rather than assumed,
which is now a one-line change to what the ledger already writes.

## Padding to reach the minimum: measured, and it loses for everyone

If a discount needs a long shared prefix, the tempting move is to manufacture one — pad short traffic with a
glossary or some few-shot examples until it clears the minimum, and let every request after the first read
from cache. `specs/runs/cache-ablation-v1.yaml` tests that directly: the same 48 classification items and the
same question, in two arms differing only in a neutral shared preamble, on three layers.

| layer | arm | prompt tokens | cached | $/1k items | passed |
| --- | --- | --- | --- | --- | --- |
| box | bare | 9,005 | 0% | $0.059 | 46/48 |
| box | padded | 133,997 | **72.5%** | **$0.673** — 11.45x | 46/48 |
| haiku-4-5 | bare | 14,644 | 0% | $0.345 | 47/48 |
| haiku-4-5 | padded | 139,636 | 0% | **$2.949** — 8.55x | 47/48 |
| sonnet-5 | bare | 14,618 | 0% | $1.034 | 47/48 |
| sonnet-5 | padded | 214,202 | 0% | **$13.508** — 13.07x | 47/48 |

**Every layer got more expensive, and not one item changed its verdict.** Quality is identical in both arms on
all three layers, which is what a deliberately neutral preamble should do and is worth having measured rather
than assumed.

The API layers got no discount at all, because neither of them does shared-prefix caching — the arm's premise
failed on the layers it was designed to favour, which is itself the finding. But the arithmetic loses even
where a discount arrives: at sonnet-5's posted $3.00 input and $0.30 cache read, a padded item that cached
perfectly would cost $0.00091 against $0.00060 bare, because a 90% discount on tokens you did not need cannot
beat a 100% discount on not sending them.

**The box's 11.45x is mostly an accounting artefact and should not be read as a cost.** It did get its
discount — 72.5% of those prompt tokens were prefix-cache hits — but the box's cost model prices every prompt
token at one rate whether or not it was a hit, while the API model discounts hits explicitly. So the ledger is
asymmetric, and asymmetric *against* the box: on prefix-sharing traffic it charges the box for work the engine
did not do. Every box result published so far is pessimistic by that amount, which is the safe direction for a
conclusion but the wrong number. Fixing it needs a measured cached-prefill rate for the box, which is a
throughput measurement rather than a guess, and until it exists the asymmetry belongs in every comparison that
involves prefix reuse.

## The tokeniser ratio, which is not about caching but is about price

Identical text, billed per each vendor's own tokeniser:

| layer | tokens for the same text |
| --- | --- |
| gpt-5.6-sol, gpt-5.6-terra, gpt-5.5, claude-haiku-4-5 | ~4,535 — x1.00 |
| gemma-4 | 4,563 — x1.01 |
| **claude-sonnet-5, claude-opus-5** | **7,245 — x1.60** |

So sonnet-5's and opus-5's posted input prices are not comparable to any other layer's without multiplying by
1.60 first. The summarisation family saw this from the other side: sonnet-5 spent 56% more prompt tokens than
the box on identical documents. Any table of posted per-token prices across these layers is wrong by that
factor unless it says otherwise.

## What this does not say

**One gateway, one day.** That `gpt-5.6-sol` caches while `gpt-5.5` needs four times the prefix, and that no
Claude model does shared prefixes at all, are far more likely facts about this gateway's configuration than
about the models. Re-run the probe when a model is added or the gateway is upgraded.

**The probes are single-shot and the cache is stateful.** `gpt-5.5` reported 0% on one identical-repeat probe
and 97.3% on another, which is a warm-up or eviction artefact, not a capability difference. Read a single 0%
as "no hit on this attempt" and only a repeated 0% across lengths and modes — which is what haiku and gemma-4
produced — as an absence.

**No cache-write premium is measured.** A first request that populates a cache is billed above plain input on
Anthropic's own API, and this gateway reports no `cache_creation_input_tokens`, so a write premium is
invisible to this ledger. The padding arithmetic above assumes writes are billed as plain input, which is the
assumption favourable to padding, and padding loses anyway.

**Minimum prefix lengths were measured on identical requests,** so the ~1k figure for `gpt-5.6-sol` and the
~2.2k for sonnet-5 are minimums for that mode. For shared prefixes the only bracket measured is `gpt-5.5`'s,
between 3.5k and 15k tokens.

**Cache lifetime is a different question.** These probes are back to back. How long a prefix survives between
turns under load is measured for the box in `results-prefix-survival.md`, where the answer is a survival curve
with a cliff rather than a fixed TTL.
