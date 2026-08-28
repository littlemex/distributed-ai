# OCRBench: the first family the box wins outright, and the gateway limit that decides part of it

Measured 2026-08-28. Box: Qwen3.6-35B-A3B-FP8 (vision tower included), TP=2 x 2 replicas, $15.2174/h,
prefix caching on. API: `claude-haiku-4-5` through the gateway. Items: 278 OCRBench questions stratified by
source dataset across 25 categories and all ten question types, fixed seed, images capped at a 1,600-pixel
long edge.

Four layers: the box, `claude-haiku-4-5`, `claude-sonnet-5`, `claude-opus-5`. The project's roster also
named gemma4, grok4.6 and the gpt-5.6 family; the gateway's `/v1/models` returns 23 Anthropic models and
none of those, so they are absent rather than substituted.

**No frontier claim on this page is final.** Two measurement defects, both mine or the gateway's rather
than the models', removed different items from different layers, and they are described below because they
matter more than the scores.

## The result

Paired over the 239 items both layers actually answered:

| | box | haiku |
| --- | --- | --- |
| passed | **207/239 = 0.866** | 168/239 = 0.703 |
| difference | **+16.3 pp** | |
| only-box wins / only-haiku wins | **49 / 10** | |
| McNemar exact | **p = 2.7 × 10⁻⁷** on 59 discordant pairs | |
| cost per item | **$0.000117** at full occupancy | $0.000311 |
| wall time for the cell | **51 s** | 369 s |

**The box is 16 points better and 2.7 times cheaper on the same items.** This is the first family measured
where it wins on quality, cost and latency at once — the classification family was a tie, the long-context
family was better but not worth its box time, and the agentic family was 1.76x more expensive.

Fifty-nine discordant pairs is worth stating next to the long-context result, which rested on a four-item
difference over 24 items. This one is comfortably past the twenty-five-to-thirty pairs a ten-point claim
needs, and the p-value is not close to the line.

## All four layers, on the 200 items all four answered

Each layer's own rate is over a different subset, so the four numbers as reported are **not comparable**:

| layer | as reported | excluded | $/1k items |
| --- | --- | --- | --- |
| box | 235/278 = 0.845 | **0** | **$0.117** |
| haiku | 168/239 = 0.703 | 39 | $0.311 |
| sonnet-5 | 212/234 = 0.906 | 44 | $1.047 |
| opus-5 | 194/201 = 0.965 | 77 | $7.733 |

The rate rises with price and so does the exclusion count, which is the whole problem: a layer that was
handed fewer items was handed the easier ones. On the 200 items every layer answered:

| layer | rate | $/1k items | latency p50 | on frontier |
| --- | --- | --- | --- | --- |
| sonnet-5 | **0.980** | $1.047 | 2.61 s | **yes** |
| opus-5 | 0.970 | $7.733 | 1.99 s | no — dominated by sonnet-5 |
| box | 0.919 | **$0.117** | **0.11 s** | **yes** |
| gpt-5.6-terra | 0.919 | $1.850 | 1.77 s | no — dominated by the box |
| haiku | 0.803 | $0.311 | 1.26 s | no — dominated by the box |

`gpt-5.6-terra` is the clearest illustration of what the table is for: it **ties the box exactly** on the
common set, and is dominated by it anyway at sixteen times the cost and sixteen times the latency. On their
own 270-item intersection the two are indistinguishable — 3.7 points, 40 discordant pairs, p = 0.154.

Four more layers — gpt-5.6-sol, gpt-5.5, grok-4.6, gemma-4 — are measuring as this is written. The roster is
reachable after all: `/v1/models` lists 23 Anthropic models, but these five answer when addressed by name, so
**the gateway under-reports its own allowlist and a roster cannot be enumerated from the API.**

**The frontier is two layers wide: sonnet-5 and the box.** haiku is dominated outright, worse than the box
at 2.7 times the cost. opus-5 is dominated by sonnet-5, and the two are statistically indistinguishable
anyway — 8 discordant pairs, p = 0.73.

**The box wins the latency axis outright**, at 0.11 s per item against 1.26 / 1.99 / 2.61 for the three APIs.
That is eleven to twenty-four times faster, and it is the axis this page nearly failed to look at.

Each pair is better compared on **its own** intersection than on the four-way one, because the four-way set
is smaller and selected differently. Doing that changes one conclusion:

| pair | n | difference | discordant | McNemar p | structure |
| --- | --- | --- | --- | --- | --- |
| box vs haiku | 239 | **+16.3 pp** | 59 | **< 0.0001** | crossing |
| box vs sonnet-5 | 234 | −3.9 pp | 27 | **0.122** | crossing |
| box vs opus-5 | 201 | −5.0 pp | 20 | 0.041 | crossing |
| sonnet-5 vs opus-5 | 200 | +1.0 pp | 8 | 0.727 | crossing |
| haiku vs sonnet-5 | 234 | −18.8 pp | 48 | < 0.0001 | crossing |
| haiku vs opus-5 | 201 | −17.4 pp | 39 | < 0.0001 | crossing |

**Sonnet-5's advantage over the box is not established** — 3.9 points on 234 items with 27 discordant pairs
gives p = 0.122. What is established is that the box beats haiku by 16 points, and that both frontier layers
beat haiku decisively. So the honest reading is: the box and sonnet-5 are not separated by this sample, at a
ninefold cost difference and a twenty-fourfold latency difference in the box's favour.

## The success sets cross everywhere, and that changes which routing policy is allowed

On SWE-bench the cheap layer's successes were a strict subset of the premium layer's — zero reversals in
twenty pairs — which is what makes cheap-then-escalate safe there: escalating can only recover, never lose.

Here **every pair crosses.** haiku won 10 items the box lost; the box won 3 that sonnet-5 lost and 4 that
opus-5 lost. Nothing nests, in either direction, at any price point. So a policy that tries one layer and
escalates on a detected failure cannot reach the union — whichever layer runs first, some of the other's
wins are unreachable. This family needs a **predictive** router, choosing per item, or it has to accept
losing one side's wins. That is a structural fact about the family rather than a preference, and it is the
one bit that decides the policy.

It is also the opposite of SWE-bench, where nesting made escalation safe. So the policy is a property of
the family, not of the gateway: **the same router cannot use one strategy everywhere.**

Where each layer wins says why:

| box wins these | haiku wins these |
| --- | --- |
| HME100k (handwritten maths) 5, NonSemanticText 5, ORAND (digit strings) 5, POIE (key information) 5, IAM (handwriting) 4 | ChartQA_Human 3, ChartQA 2, NonSemanticText 2 |

**The box is better at reading; haiku is better at reasoning over a chart.** That is a model-by-family
interaction reproducing across several categories rather than one lucky item, which is the bar an advisor
set for calling something a strength: not "scored well" but "its rank rises here relative to elsewhere".

## The gateway refuses the hardest 14% outright

The 239 above is not 278 because **39 items failed on the API side with HTTP 422, `content exceeds 200000
char`**. The gateway caps request content at 200,000 characters, and a base64-encoded photograph of a
document page exceeds it. The failures are not spread evenly:

| category | refused / in sample |
| --- | --- |
| docVQA | **11 / 12** |
| SROIE | 8 / 12 |
| FUNSD | 7 / 12 |
| infographicVQA | 7 / 12 |
| textVQA | 5 / 12 |
| ESTVQA | 1 / 12 |

Exactly the document-heavy categories — the largest images, and the OCR work with the most obvious business
value. **The box answered all 39, scoring 28/39 = 0.718 on them.**

So part of this family's answer is not about model quality at all — but the first version of this page
overstated it as "through this gateway these requests cannot be served by an API at any price". **That is
wrong.** Adding `gpt-5.6-terra` produced **zero** `request_too_large` failures on the same 278 images: the
200,000-character cap belongs to the gateway's **Anthropic route**, not to the gateway. Its OpenAI-style
route accepts the same images that its Anthropic shim refuses.

Which is a more useful fact than the wrong one it replaces. The document-heavy items are servable by an API
— just not by an Anthropic model through this gateway. That is a **route** constraint, and a router has to
model it as one: the same image is deliverable to some layers and not others, independently of price or
quality. Two more things follow:

* The naive comparison (0.845 over 278 against 0.703 over 239) is **invalid** — different item sets, and the
  set the API got is systematically easier. Only the paired figure is comparable, which is why the runner
  drops a pair excluded on either side rather than counting the half that exists.
* Re-fetching at a lower resolution is still worth doing, so the Anthropic layers can be compared on the
  full set — but it is now a *convenience* rather than the only way to measure those items, and the smaller
  images must go to every layer so the cost of downscaling is paid equally.
* The cap is per route, so it belongs in the table as a per-layer exclusion cause rather than a property of
  the family. `request_too_large` on three layers and `empty_reply` on a fourth is exactly the distinction
  the routing table buckets by cause.

## The protocol asymmetry, which cost a whole run to find

The box accepts OpenAI `image_url` content parts on its chat endpoint. The gateway's OpenAI shim refuses
them and says so on a 400: *"image_url content parts are not supported; use the Anthropic /v1/messages
endpoint with base64 images"*. The first run recorded 278 transport failures on every API layer and a
perfectly good 278-item box cell, then exited non-zero from the paired comparison — a successful run looking
like a crashed job.

`Layer` now carries `image_style` and `messages_endpoint`, the client translates content parts to
Anthropic's `source: {type: base64, ...}` shape, and the spec **refuses** `image_style: anthropic` without
an endpoint. A multimodal family costs a second wire format that a text family never sees, and the
asymmetry belongs in the client rather than the task.

## The second defect: a token cap silently removed a premium model's hardest third

`max_tokens=48` was chosen so the containment metric could not be gamed by verbosity. **It removed 38 of
opus-5's items**, and it did it invisibly: every one hit `finish_reason: max_tokens` at exactly 48 tokens
having emitted **no text at all**. opus-5 spends the budget before it says anything, so a cap that a
short-answer model never notices truncated a reasoning model to silence. Those 38 replies carried no error,
so they were excluded as unusable rather than counted wrong — correct behaviour hiding a design fault.

Which means opus-5's 0.965 is over a **doubly** filtered subset: the gateway dropped 39 large images, and
the cap dropped 38 more where the model wanted to think longer, and wanting to think longer correlates with
difficulty. It is the easiest 72% of the sample, and it is why the "opus-5 below sonnet-5" ordering above
must not be quoted.

The fix is not a bigger cap for its own sake. The metric's honesty already has a guard — `match_budget`
truncates the *prediction before matching*, so verbosity cannot buy a hit — and `max_tokens` was doing that
job a second time and worse. Raise the cap, keep the guard.

Both defects share a shape worth naming: **a constraint chosen for one layer silently re-sampled the items
for another.** The exclusion counts, 0 / 39 / 44 / 77, were the visible symptom and were sitting in the
summary the whole time.

## What this does not say

* **The box's cost figure here is derived from text-measured token rates**, and they are the wrong rates for
  images: the vision encoder is separate work and image tokens have their own prefill profile. The 7.7
  box-seconds for 278 items is measured wall time and is trustworthy; the dollar figure built on
  $0.236/Mtok is not, until a vision perf cell exists. That cell is the next thing this family needs.
* **Nothing about throughput under load.** Every cell here is one request at a time. Whether images pressure
  the KV pool the way long text does, and whether the cache findings transfer at all to a family with no
  shared prefixes, is unmeasured.
* **278 items over 25 categories is thin per category** — five wins in a category is five items. The
  aggregate difference is solid; the per-category breakdown is a hypothesis about where to look next.
* **Neither frontier is final until a re-run** with images small enough for the gateway and a cap large
  enough for a reasoning model, sending identical inputs to every layer. The direction — box and sonnet-5 on
  the frontier, haiku dominated, every pair crossing — is unlikely to reverse, but the numbers will move and
  the opus-5 ordering may.
* **`sends_temperature` is a real difference, not bookkeeping.** sonnet-5 and opus-5 reject the parameter
  ("`temperature` is deprecated for this model"), so their answers are not pinned the way the box's and
  haiku's are. A quality cell that cannot fix temperature is measuring a distribution rather than a point,
  and a rate from it deserves a wider interval than the arithmetic suggests.
