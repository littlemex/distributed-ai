# Long-document summarisation: the box matches a premium API at a thirteenth of the price

Measured 2026-08-28. Box: Qwen3.6-35B-A3B-FP8, TP=2 x 2 replicas, $15.2174/h, prefix caching on. APIs
through the gateway: `claude-haiku-4-5` (the baseline the floor is defined against), `claude-sonnet-5`,
`gemma-4`. Items: 80 GovReport test documents, stratified by length across four bins from 11,516 to 116,680
characters, median 39,896, fixed seed. One request per item, temperature 0, 700 output tokens except
`claude-sonnet-5`, which needs 2,048 because it spends budget before it speaks.

**Read the metric section first.** The scorer this family shipped with was inverted, and the correction
moved every layer. The numbers below are the third scoring of one set of replies, and the first two are on
the page because which one you believe is the whole question.

## The result

| layer | rate | $/1k items | latency p50 | on the frontier |
| --- | --- | --- | --- | --- |
| **box-qwen36-tp2x2** | **0.812** | **$4.505** | 5.28 s | **yes** |
| api-sonnet-5 | 0.800 | $58.313 | 10.55 s | no, dominated by the box |
| api-haiku-4-5 | 0.725 | $13.109 | 7.38 s | no, dominated by the box |
| **api-gemma-4** | 0.700 | **$1.548** | **4.73 s** | **yes**, as the cheapest and the fastest |

`gemma-4`'s cost on this page has been wrong twice, in both directions, and the number above is the third. It
was first $3.470, from a rate typed into the spec by hand at $0.30 input. It was then $60.000, from importing
the gateway's own rate card — which turned out to price this model at a `default` row the card itself describes
as a deliberate over-charge for models it does not know, and which put it at the top of the family instead of
the bottom. **AWS publishes $0.14 input and $0.40 output** for `google.gemma-4-31b` in us-east-2, the region
this gateway serves it from, at the `standard` service tier, which gives the $1.548 above. So it is the
cheapest layer in this family by 2.9x over the box, and the second attempt at fixing the first attempt was the
furthest from the truth.

The correction moved no quality number and no other layer's cost here: haiku's and sonnet-5's rates are
corroborated by two independent sources. See `routing-table.md` for how prices resolve now, and `benchctl
price` for re-pricing a recorded run without re-running it.

The box's cost is per item at full occupancy, which is the only honest way to price a fixed-cost box and is
kept in its own ledger all the way to disk. Every rate is over the same 80 items — all four layers answered
all of them, with nothing excluded on any side — so unlike the OCRBench page these four numbers are directly
comparable.

Paired, over those 80 items:

| pair | difference | discordant | McNemar exact |
| --- | --- | --- | --- |
| box vs sonnet-5 | +1.2 pp | 9 | p = 1.000 |
| box vs haiku-4-5 | +8.8 pp | 15 | p = 0.119 |
| box vs gemma-4 | **+11.2 pp** | 13 | **p = 0.023** |
| sonnet-5 vs gemma-4 | **+10.0 pp** | 10 | **p = 0.022** |
| sonnet-5 vs haiku-4-5 | +7.5 pp | 12 | p = 0.146 |
| haiku-4-5 vs gemma-4 | +2.5 pp | 12 | p = 0.774 |

So the quality claim is narrow and worth stating exactly: **the box is indistinguishable from
`claude-sonnet-5` and from `claude-haiku-4-5`, and better than `gemma-4`.** What is not narrow is the
price. Against the layer it ties with, the box costs $4.505 per thousand items against $58.313 — **12.9x
cheaper** — and answers in half the time at the median.

Against the baseline the family's floor is written against, the box is non-inferior at the declared 5-point
margin, with a one-sided 80% lower bound of +5.0 pp on a difference of +8.8. That verdict does not rest on
the margin, because the bound is above zero: any margin would have returned the same answer. Which is just
as well, since 15 discordant pairs out of 80 at this confidence can certify no margin tighter than 5.0 pp,
and a margin finer than that would have been a claim the design could not have refused.

The verdict holds at all eight threshold settings the calibration cannot distinguish. That check exists
because a single-cell verdict would not be one.

## Why this family, and the premise confirmed rather than assumed

An advisor named this as the box's second candidate to win, and the reasoning was structural. A single-shot
summary of a long report has a long prefill and **no prefix reuse**, so the API's cache discount does not
apply — and an assumed API cache discount is the entire reason the box came out 1.76x *more* expensive on
agentic traffic, where against the same API with no cache it was 3.0x cheaper. "Assumed" is the correction:
`cache-discount-eligibility.md` later measured that the API in that comparison never caches on this gateway at
all, so the family this page contrasts itself with is a hypothetical one.

Across 2.83 million prompt tokens sent to the three API layers, the gateway reported **1,008 cached prompt
tokens: 0.04%.** That number needs a qualifier it did not originally have, because a later probe
(`cache-discount-eligibility.md`) established that **`claude-haiku-4-5` and `gemma-4` never cache on this
gateway at all** — not automatically, not when asked with an explicit `cache_control` breakpoint, not through
either route it offers. For those two layers, zero cached tokens is what any run would report, so it is no
evidence about this family.

For `claude-sonnet-5` it is evidence, and good evidence: that layer caches automatically, with no flag, on any
shared prefix past about 2,200 tokens, and it still reported zero here. The premise holds for the layer that
could have benefited. It holds for the other two as well, but by the structural argument rather than by the
measurement: each document is unique and the shared instruction preamble is roughly 40 tokens, which is two
orders of magnitude below any minimum measured on this gateway.

One number in the same table is worth noticing for a different reason: `claude-sonnet-5` consumed 1,222,922
prompt tokens for the same 80 documents against the box's 784,839, 56% more for identical inputs. Per-token
prices are not comparable across tokenisers, and this is how much that matters.

## The metric was inverted, and fixing it is most of this page

`benchctl` splits `response` from `score` so that what happened never changes and what it is worth can be
corrected. This family is why that was worth building.

**v1 (0.887 box, 0.812 haiku, 0.900 gemma-4, 0.812 sonnet-5).** The rule was: carry at least 30% of the
reference summary's checkable atoms, invent no numbers at all, and stay under a quarter of the source's
length. Scoring the gold reference summary as if a model had written it puts the metric's ceiling at
**0.40**, because a reference legitimately writes "$1.4 billion" where the report says "1,432 million" and
exact matching calls that an invention about 1.2 times per summary. Scoring the document's own first 300
words — an extract, not a summary — gives **0.48**. The metric ranked a non-summary above the human
reference, because the cheapest way to pass was to write no numbers of your own, and copied prose has none.
`gemma-4` led that table at 0.900.

Nothing was broken in the code. The thresholds had never been asked whether the best possible answer could
satisfy them.

**v2 (0.812, 0.600, 0.700, 0.750).** Thresholds pinned to controls instead of taste, by
`scripts/calibrate_summarise.py`: fifteen of them, five gated, non-zero exit when a setting cannot keep them
apart. Figures are matched under unit rescaling and rounding at the candidate's own precision, in both
directions, so "1.4 billion" both carries the reference's figure and is supported by the document's. An
acronym the document itself defines stands for its expansion. The fabrication rule became a share of the
figures written rather than a flat count, because the flat count punished dense summaries and forgave a
summary that wrote four numbers and invented three. Thresholds were frozen and committed before any layer
was re-scored.

**v3 (0.812, 0.725, 0.700, 0.800).** One v2 gate came out. A function-word floor had been added to close
the only blind spot the controls found — a list of the document's entities passing at 0.70 — on the
reasoning that grammar separates prose from a list where recall cannot. It cut atom soup to 0.10. It also
rejected twelve of `claude-haiku-4-5`'s summaries, which are headed, correct Markdown whose function words
are diluted by their own headings, and the two distributions turn out to touch: haiku's terse minimum is
0.156 against the entity list's 0.149. No threshold separates them, so there was never a gate to have.

That amendment came after the layers had been scored, which is the one direction such a change must not be
made in. What licenses it is that the gate's claim was disproved by measurement, and that the change moves
every terse-writing layer **up**: haiku from 0.600 to 0.725, sonnet-5 from 0.750 to 0.800, gemma-4 and the
box unchanged. It helps the box's competitors and gives the box nothing. It cut the box's lead over the
baseline from +21.2 pp to +8.8, and turned that lead from significant (p = 0.0005) into not (p = 0.119). A
metric change that narrows your own result is the only kind that is safe to make late.

The gap that let the bad gate ship was a missing control: it was calibrated against atom soup with nothing
representing the register real summaries are written in. That control now exists and passes at 0.89.

### What the controls say at the frozen thresholds

| control | rate | what it establishes |
| --- | --- | --- |
| best 300-word selection from the reference | 0.99 | the ceiling: the floor is achievable |
| the reference truncated at 300 words | 0.88 | a plain truncation still mostly passes |
| the reference, paraphrased and rescaled | 0.89 | matching is not brittle to abstraction |
| the reference as headed, bulleted Markdown | 0.89 | nor to the register the layers write in |
| the document's own first 300 words | 0.16 | an extract is not a summary |
| a 300-word window from the document's middle | 0.12 | and that is not a quirk of the lead |
| every figure multiplied by 1.07 | 0.04 | fabrication is caught |
| every figure replaced by a random one | 0.04 | and the support rule is not vacuous |
| another report's reference summary | 0.00 | the metric is about *this* document |
| an empty answer | 0.00 | the edges behave |
| the document's atoms listed without prose | 0.70 | **a blind spot: coverage alone passes** |
| the reference with its figures permuted | 0.88 | **and so does a scrambled summary** |

## What this does not say

**`passed` does not mean faithful.** It means carried the reference's atoms, invented no figures, and stayed
short. Permuting a summary's figures among their slots leaves every atom present and every figure supported
by the document, and it scores 0.88 — level with the unpermuted ceiling. Both advisors named that blind spot
before it was measured, and closing it needs something judge-like or entailment-like, which this family
deliberately does not have. The size of the hole is on the record instead of in a footnote.

**The fabrication check never decided anything here.** It fails the ×1.07 control at 0.04 and rejects 7 in 8
random figures, so it works. But no layer trips it anywhere in the admissible threshold range: what
separates these four layers is recall. The check is insurance, and on this run it did not pay out.

**Recall is measured against the full reference, not a truncation of it,** while the prompt asks for 300
words and the references run to about 600. So the floor is a claim about carrying roughly half of a longer
summary's checkable content, and it is calibrated to be achievable rather than assumed to be. A reference's
closing 300 words pass at 0.59 against its opening 300 words at 0.88, which is the size of the penalty a
valid but back-loading selection pays. The atoms are also weighted equally, so a figure in a methodology
footnote counts the same as the headline finding.

**One box configuration, one gateway, one dataset in one language.** GovReport is English government prose;
nothing here transfers to Japanese long-document summarisation without measuring it.

**`gemma-4`'s cost has been stated three ways on this page in one day**, spanning a factor of 39, and only the
third has a source anyone can check. The lesson is not that a number was wrong; it is that the most
official-looking source available — the serving gateway's own rate card — was the *worst* of the three, because
it deliberately over-charges models it has no rate for and says so in a comment nobody read. Its quality
deficit against the box and against sonnet-5 was real throughout at p = 0.023 and p = 0.022, so the quality
ranking never depended on any of it.

**The box's price is not from a rate card at all** and is not comparable in kind: it is an hourly machine cost
divided by measured throughput at full occupancy. At half that occupancy the same work costs twice as much.
