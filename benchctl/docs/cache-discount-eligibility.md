# The prompt-cache discount is not a property of APIs, and it cannot be manufactured

Measured 2026-08-28 through the gateway, by `scripts/probe_cache_eligibility.py`. Two identical requests back
to back, and the provider's own cached-token count on the second one. Nothing here rests on a published
policy.

The discount matters more than any other single term in this project's arithmetic: it is the entire reason the
box came out **1.76x more expensive** on agentic traffic where, with caching off, it was **3.0x cheaper**. It
had never been measured per layer. It should have been, because it is not uniform, and reasoning about "the
API's cache discount" as though it were a property of APIs turns out to be wrong in three separate ways.

## Which layers are discounted at all

| layer | cached without asking | cached when asked | tokens for identical text |
| --- | --- | --- | --- |
| claude-sonnet-5 | **yes, 99.9%** | yes | 7,245 — **x1.60** |
| claude-opus-5 | **yes, 99.9%** | yes | 7,245 — **x1.60** |
| gpt-5.6-sol | **yes, 99.9%** | yes | 4,535 — x1.00 |
| gpt-5.6-terra | **yes, 99.9%** | yes | 4,535 — x1.00 |
| claude-haiku-4-5 | no, 0% | **no, 0%** | 4,537 — x1.00 |
| gemma-4 | no, 0% | **no, 0%** | 4,563 — x1.01 |
| gpt-5.5 | no, 0% | **no, 0%** | 4,535 — x1.00 |

`grok-4.6` is in the OCRBench spec but the gateway's allowlist rejects the id under the names tried here, so
it is absent rather than measured.

**The first wrong assumption: that a discount can be requested.** It cannot, either way. Every layer that
caches does so automatically with no `cache_control` breakpoint, and every layer that does not cache stays at
zero when given one — including through the gateway's Anthropic `/v1/messages` route, which additionally
mangles content parts (it billed 9 input tokens for a 2,700-token request, having dropped the preamble). So
`benchctl`'s client is not leaving anything on the table by never sending a breakpoint, which is worth knowing
because it looked like a defect when the question was first asked.

**The second wrong assumption: that the discount is the API tier's advantage.** It is the *premium* tier's
advantage. `claude-haiku-4-5` and `gemma-4` — the cheap layers the box actually competes with on price — get
no discount on this gateway at any prefix length. They pay full price for every token of every request,
forever, no matter how much prefix their traffic shares. `gpt-5.5` likewise, while `gpt-5.6-sol` and
`gpt-5.6-terra` do cache, so this does not even divide cleanly by vendor or by recency.

**And a third thing, not an assumption but a correction:** `claude-sonnet-5` and `claude-opus-5` read
identical text as **1.60x** as many tokens as everything else. Their posted input price is therefore not
comparable to a posted price from any other layer without multiplying by 1.60 first. This is the same effect
seen from the other side on the summarisation family, where sonnet-5 spent 56% more prompt tokens than the box
on identical documents.

## The shortest prefix that earns it

Sweeping the shared prefix in one-clause steps, on the layers that cache:

| layer | no discount at | discounted at |
| --- | --- | --- |
| gpt-5.6-sol | 685 tokens | 1,035 tokens |
| claude-sonnet-5 | 2,125 tokens | 2,245 tokens |

So roughly **1k tokens of shared prefix for the gpt layers and roughly 2.2k for sonnet-5**, and below that
there is no discount at any hit rate. That immediately rules the discount out for whole families rather than
for individual requests: a classification item is about a hundred tokens and a translation request a few
hundred, so neither can reach the minimum on its own content.

## Why it cannot be manufactured, which is the part that decides routing

The obvious move, once the minimum is known, is to pad short traffic with a shared preamble — a glossary,
some few-shot examples — until it clears the bar and every request after the first reads from cache. The
arithmetic says not to, and it is worth doing explicitly, for one classification item on `claude-sonnet-5` at
its posted $3.00 input, $0.30 cache read and $15.00 output per million:

| | prompt tokens | input cost | output cost | total |
| --- | --- | --- | --- | --- |
| minimal prompt, no discount possible | 120 | $0.00036 | $0.00024 | **$0.00060** |
| padded to 2,245 so it caches, then read at 10% | 2,245 | $0.00067 | $0.00024 | **$0.00091** |

**Padding to reach the minimum costs 1.5x more than not padding**, even with a 90% discount on every token
of it. That is not a near miss to be tuned away: a 90% discount on tokens you did not need cannot beat a 100%
discount on not sending them. The cache discount only ever reduces the cost of a prefix the traffic already
had to carry.

Which gives the routing rule this project was looking for, and it is narrower than expected:

- **The API's cache advantage exists only where traffic already carries a long shared prefix** — a system
  prompt, tool definitions, an accumulating conversation. That is the agentic family, and it is exactly where
  the box lost, 1.76x.
- **It cannot be created for traffic that does not have one.** Padding is a net loss.
- **It is unavailable to the cheap tier entirely on this gateway.** Against `claude-haiku-4-5` or `gemma-4`
  the box competes at full API price on every family, and no amount of prefix sharing changes that.
- **And where it does apply, the 1.60x tokeniser ratio eats part of it** for the two Claude layers that have
  it.

## What this does not say

**One gateway.** Every number here is this gateway's behaviour, not the upstream providers'. A gateway can
strip `cache_control`, fail to pass a cache-eligible request through as one, or route the same model id to a
deployment with caching disabled. That `gpt-5.6-sol` caches while `gpt-5.5` does not, on the same route, is
more likely a fact about the gateway's configuration than about the models.

**Nothing here measures the cache-write premium.** A first request that populates a cache is billed above
plain input on Anthropic's own API, and this gateway reports no `cache_creation_input_tokens`, so a write
premium would be invisible to `benchctl`'s accounting. The arithmetic above assumes writes are billed as plain
input, which is the assumption favourable to the padding strategy — and the strategy loses anyway.

**Cache lifetime is not measured here.** These probes are back to back. How long a prefix survives between
turns is a different question, measured for the box in `results-prefix-survival.md`, where the answer is a
survival curve with a cliff rather than a fixed TTL.

**The discount is per shared prefix, not per family.** A family below the minimum today clears it the moment
its prompt grows a glossary it actually needed. The rule is about what the traffic carries anyway, and that
is a product decision as much as a measurement.
