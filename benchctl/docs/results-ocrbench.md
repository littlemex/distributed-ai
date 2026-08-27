# OCRBench: the first family the box wins outright, and the gateway limit that decides part of it

Measured 2026-08-28. Box: Qwen3.6-35B-A3B-FP8 (vision tower included), TP=2 x 2 replicas, $15.2174/h,
prefix caching on. API: `claude-haiku-4-5` through the gateway. Items: 278 OCRBench questions stratified by
source dataset across 25 categories and all ten question types, fixed seed, images capped at a 1,600-pixel
long edge.

`claude-sonnet-5` and `claude-opus-5` cells are still running and are not in this page. The project's
roster also named gemma4, grok4.6 and the gpt-5.6 family; the gateway's `/v1/models` returns 23 Anthropic
models and none of those, so they are absent rather than substituted.

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

## The success sets cross, and that changes which routing policy is allowed

On SWE-bench the cheap layer's successes were a strict subset of the premium layer's — zero reversals in
twenty pairs — which is what makes cheap-then-escalate safe there: escalating can only recover, never lose.

Here **haiku won ten items the box lost.** The sets intersect rather than nest, so a policy that tries cheap
first and escalates on a detected failure cannot reach the union: whichever layer runs first, some of the
other's wins are unreachable. This family needs a **predictive** router — choose per item — or it needs to
accept losing one side's wins. That is a structural fact about the family, not a preference, and it is one
bit that decides the policy.

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

So part of this family's answer is not about model quality at all: through this gateway, these requests
cannot be served by an API, at any price, because they do not fit in a request. That is a routing fact, and
it is the kind this project exists to surface. Two things follow:

* The naive comparison (0.845 over 278 against 0.703 over 239) is **invalid** — different item sets, and the
  set the API got is systematically easier. Only the paired figure is comparable, which is why the runner
  drops a pair excluded on either side rather than counting the half that exists.
* The next run should re-fetch at a lower resolution so nearly everything fits, and send the *same* smaller
  images to both layers. Downscaling costs OCR accuracy, so it must cost both sides equally.

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
* **Two layers, not four.** The mid and premium cells are still running, and the interesting question they
  answer is whether premium recovers the chart-reasoning items the box loses, which would make a predictive
  router worth building rather than merely necessary.
