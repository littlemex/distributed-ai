# Per request the box is cheaper; per solved task it is not, unless its cache is on

Measured from the 120 real SWE-bench episodes this project already ran, 2026-08-29. No new spend: the pilot
recorded per-step model, prompt tokens, cached tokens, completion tokens and outcome for every one of 2,228 model
calls, and the question below is answerable from those records.

## Why this had to be checked

Both advisors ranked "run the agentic API arm for real" second, and the reason one of them gave is sharper than
the one this project had been carrying. The objection is not that per-token billing might be inaccurate — it is
exact. It is that **computing an API's agentic cost from the box's token counts assumes the API takes the same
trajectory**: the same number of turns, the same output lengths, the same retries. Agentic trajectories are
model-dependent and errors compound across turns, so a per-request price cannot be turned into a per-task price
by multiplication.

That is testable from data on disk, and it turns out to be true by an order of magnitude.

## The trajectories are not comparable

Single-model policies on the same SWE-bench instances, median per episode:

| model | solved | steps | prompt tokens | output tokens |
| --- | --- | --- | --- | --- |
| claude-fable-5 | 19/24 = 79.2% | **5** | 20,856 | 2,876 |
| gpt-5.6-terra | 23/40 = 57.5% | **8** | 41,560 | 2,384 |
| **Qwen3.8-27B (the box)** | 9/24 = 37.5% | **27** | **304,612** | 1,393 |

**The box takes 27 steps where fable-5 takes 5, and reads 15 times as many prompt tokens.** Per instance the gap
is wider still: on `django__django-17084` the box spent 40 steps where gpt-5.6-terra spent 1, and on
`matplotlib__matplotlib-26208` 40 against 1. So any figure computed by pricing one model's token counts at
another's rates is wrong by roughly the ratio of their trajectories, and the direction is not favourable to the
box.

## Cost per solved task, which is the unit that survives that

Priced with the sourced rates — AWS Price List and vendor list for the APIs, measured throughput for the box —
and each layer's own measured cache hit rate on this traffic (gpt-5.6-terra 94.0%, claude-fable-5 51.8%, the box
0% because the pilot ran before the prefix-caching flag was fixed):

| model | $/episode | solve rate | **$/solved task** |
| --- | --- | --- | --- |
| gpt-5.6-terra | $0.0455 | 57.5% | **$0.0792** |
| Qwen3.8-27B, as run | $0.0776 | 37.5% | **$0.2070** — 2.61x gpt-5.6-terra |
| claude-fable-5 | $0.2551 | 79.2% | **$0.3222** |

**Per solved task the box is 2.61x more expensive than `gpt-5.6-terra`, on a cheaper token.** It needs 3.4x the
steps and solves 1.5x less often, and those multiply.

That is the number as the pilot ran, and the pilot ran with the box's prefix caching off — the flag bug
documented in `results-agentx.md`. With caching at the 82.5% measured elsewhere on prefix-reusing traffic:

| box | $/episode | $/solved task | vs gpt-5.6-terra |
| --- | --- | --- | --- |
| caching off, as run | $0.0776 | $0.2070 | 2.61x dearer |
| **caching on at 82.5%** | **$0.0230** | **$0.0615** | **0.78x — 1.3x cheaper** |

So the trajectory penalty is survivable, but **only** because the box's cached prompt token costs $0.0188 per
Mtok against every API's cached rate being an order of magnitude higher. Turn the cache off and a 3.4x trajectory
penalty on a 9x cheaper token still loses.

## The part that is not about cost

Paired on the instances both layers attempted:

| comparison | box | other | only other solved | only box solved | McNemar exact |
| --- | --- | --- | --- | --- | --- |
| box vs gpt-5.6-terra | 9/24 | 13/24 | 4 | **0** | p = 0.125 |
| box vs claude-fable-5 | 9/24 | 19/24 | 10 | **0** | **p = 0.002** |

**The box solved zero instances that either API failed.** Its successes are a strict subset of theirs, on both
comparisons. Against `claude-fable-5` the 41.7-point gap is significant; against `gpt-5.6-terra` the 16.7-point
gap is not, at four discordant pairs — but a null result on four pairs is "not distinguished", and the
zero-unique-solves observation is not weakened by it, because it needs no test: it is a count.

This reproduces, on paired data and with an outcome rather than a score, the nesting result this project found
earlier on other families: the cheap layer's wins live inside the expensive layer's. Cost per solved task is
therefore the *only* honest unit here, because a cheaper layer that solves a subset is not substituting for the
expensive one — it is doing less work for less money.

## What this changes

`results-agentx.md` reports the box as **3.0x cheaper** than the cheapest API on agentic traffic, and this page
does not contradict that: it is a different unit. That figure is per *request*, against `claude-haiku-4-5`, which
returns no cached tokens on this gateway. Per *solved task*, against `gpt-5.6-terra`, which does cache at 94%,
the box is 1.3x cheaper with its cache on and 2.6x dearer with it off.

The routing consequence is narrower than either number alone:

- **Agentic traffic to the box requires its prefix cache to be working**, not as an optimisation but as the
  condition for the comparison to hold at all. The router outage documented in `results-agentx.md` — two days of
  silently routing past the affinity layer — would have inverted this result while every dashboard stayed green.
- **And it requires accepting a lower solve rate**, which is not a cost question. Whether 37.5% against 57.5% is
  acceptable depends on what the unsolved tasks cost, which this project has never measured.

## What this does not say

**The box measured here is not the current box.** The pilot ran Qwen3.8-27B; the box everywhere else in this
project is Qwen3.6-35B-A3B, which is a different model on different hardware. The trajectory finding is about the
class of comparison and holds regardless, but the specific 27 steps and 37.5% belong to the older box, and
re-running the pilot on the current one is the obvious next measurement.

**Twenty-four instances.** Solve rates on 24 SWE-bench instances are noisy, and the 82.5% cache substitution
comes from a different, synthetic traffic shape — the agentic measurements themselves put it between 84.96% and
92.53%, so 82.5% is conservative and the box's cached figure is if anything better than shown.

**The box's rates are the current box's, applied to the older box's token counts.** That is a substitution, made
because no measured throughput exists for Qwen3.8-27B, and it is the reason the dollar figures here should be read
at one significant figure while the ratios are read as ratios.
