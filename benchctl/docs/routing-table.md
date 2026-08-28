# The routing table: measurements that survive a model being added

A router needs a table, and a table has to survive models arriving one at a time. This is the shape that
survives, and the reason for it is one run: on OCRBench four layers reported 0.845, 0.703, 0.906 and 0.965,
and **not one of those numbers was comparable to another**, because each layer answered a different subset —
0, 39, 44 and 77 items excluded, for two unrelated reasons. A table of headline rates would have recorded a
clean-looking ranking that was an artifact of which items each layer was permitted to attempt.

## What it stores

**Per-item verdicts, not rates.** Everything else is derived on read:

* Any pair of layers is compared on the intersection of what they both answered, at any time, with no
  re-running. **Adding a model means measuring it once against the fixed item set and merging**; its
  comparison against everything already there is arithmetic.
* Each pair is compared on *its own* intersection rather than the all-layers one, which uses more data.
  That mattered immediately: box against sonnet-5 is p = 0.004 on the 200 items all four answered and
  **p = 0.122 on the 234 those two share.** The second is the better estimate and it reverses the reading.
* The bit that decides routing policy falls out for free — whether one layer's successes are a **subset** of
  another's, in which case escalation can only recover, or whether they **cross**, in which case escalation
  cannot reach the union and the family needs a predictive router. SWE-bench nested; every OCR pair crosses.
  It is a property of the family, so it is stored per family.
* Exclusions are bucketed **by cause**, because the cause decides whether a failure is the model's fault. On
  OCR the buckets were `request_too_large` (39 on every API layer — the gateway's content cap) and
  `truncated_before_any_text` (38 on opus-5 — a token budget that silenced a reasoning model). Neither is a
  quality signal, and "excluded: 77" would have lost that.
* Caveats that make two rates different *kinds* of measurement are attached to the layer:
  `temperature_not_pinned` where a model rejects the parameter, `cost_basis=box_hour_at_full_occupancy`
  where the number is a rate rather than a bill, `pricing_placeholder` where cost is not comparable at all.
* Item sets cannot drift. Each suite carries a fingerprint of its item ids and merging a layer measured
  against different items is **refused**, because that is exactly how four incomparable rates become a
  ranking.

## What it deliberately does not store

No policy, no weighting, no recommendation. The table is evidence; turning three axes into one choice
belongs to the caller. `frontier()` will say which layers are not dominated on quality and cost, which needs
no exchange rate, and stops there.

## Using it

```bash
benchctl table specs/runs/<run>.yaml --run-dir /artifacts/runs/<run-id> --out routing-table.json
```

Merging is idempotent per (suite, layer): re-running a layer replaces its entry and every pair involving it
is recomputed, so a stale comparison cannot survive a merge.

## Adding models later, which is the point

The intended shape, not built yet because the families are still moving:

1. A model list and a family are the inputs. For each new layer, generate a cell against the **existing**
   suite — same items, same fingerprint — and run only that cell.
2. Merge. Every pairwise comparison against the models already in the table appears without re-measuring
   any of them. Cost per item and latency come from the same run.
3. Screen cheaply first. Both advisors argued for a coarse pass at 30–50 items to pick one representative
   per price band, then the full set only for frontier candidates: measuring every model on every family
   costs a lot and teaches little about which model is needed where.

Two constraints on that script, learned the hard way today:

* **A new model may reject parameters an old one accepted.** sonnet-5 and opus-5 refuse `temperature`, the
  gateway reports that as a 502, and 502 was retryable — so 278 items retried four times each and one cell
  took forty minutes to fail for a reason nothing surfaced. A model-onboarding script has to probe the
  parameter surface once and record it, and a 5xx wrapping a validation error must never be retried.
* **A new model may need a different token budget.** A cap that a short-answer model never notices truncated
  a reasoning model to silence on 38 items, with no error, and the exclusion count was the only symptom. Per
  model, not per suite.

## What the table says today

`specs/routing-table.json`: two suites now. `ocrbench-stratified-278` with **nine layers** over 278
items, and `govreport-stratified-80` with four over 80, which is the point of storing per-item verdicts —
the second family was merged in, not averaged in, and the OCR numbers did not move.

### ocrbench-stratified-278, on the 195 every layer answered

| layer | rate | $/1k items | latency p50 | frontier |
| --- | --- | --- | --- | --- |
| api-sonnet-5 | **0.980** | $1.047 | 2.61 s | **yes** — most accurate |
| api-opus-5 | 0.974 | $7.733 | 1.99 s | no |
| **api-gemma-4** | **0.974** | **$0.108** | 0.97 s | **yes** — near-top accuracy at the lowest price |
| api-gpt-5.5 | 0.959 | $2.763 | 1.90 s | no |
| api-gpt-5.6-sol | 0.949 | $1.992 | 2.20 s | no |
| api-grok-4.6 | 0.949 | $3.334 | **8.64 s** | no — dominated by four layers |
| **box-qwen36-tp2x2** | 0.923 | $0.117 | **0.11 s** | **yes** — nine times the fastest API |
| api-gpt-5.6-terra | 0.923 | $1.850 | 1.77 s | no |
| api-haiku-4-5 | 0.810 | $0.311 | 1.26 s | no |

**Three layers on the frontier, one per axis.** sonnet-5 is the most accurate, gemma-4 is within a whisker
of it at a tenth the price, and the box answers nine times faster than anything else. Six of nine are
dominated, and grok-4.6 is dominated by four separate layers — least accurate of the expensive group, most
expensive but one, and eight times slower than the box.

**Almost nothing here is separable on 278 items.** Nearly every pair returns p > 0.1: gemma-4 against the box
is 1.4 points with p = 0.597, gemma-4 against sonnet-5 is p = 0.581, gemma-4 against opus-5 is p = 1.000.
The only significant results are the wins over haiku and gpt-5.6-terra. An advisor's warning that a
ten-point claim needs 25–50 discordant pairs and 150–300 items is borne out from the other side: the
differences here are one to three points and need far more items than that.

### govreport-stratified-80, on all 80, which all four layers answered

| layer | rate | $/1k items | latency p50 | frontier |
| --- | --- | --- | --- | --- |
| **box-qwen36-tp2x2** | **0.812** | **$4.505** | 5.28 s | **yes** — best quality on the frontier |
| api-sonnet-5 | 0.800 | $58.313 | 10.55 s | no — dominated by the box |
| api-haiku-4-5 | 0.725 | $13.109 | 7.38 s | no — dominated by the box |
| **api-gemma-4** | 0.700 | **$3.470** | 4.73 s | **yes** — the cheapest |

The two suites disagree about the box, and that is the finding rather than a problem. On OCRBench it is
0.923 against sonnet-5's 0.980 and loses on quality; here it is 0.800 against sonnet-5's 0.800 and wins on
price by 12.9x. Both are true, they are different traffic, and a single table entry per layer would have had
to average them into something false. The same table holds `score_version` per layer, because the
summarisation family's first scorer was inverted and what belongs here is the corrected opinion.

The reason the box's price advantage is so much larger on this family is structural and now measured: these
requests have a long prefill and no prefix reuse, so the API's cache discount does not apply. Across 2.83
million prompt tokens the gateway reported 0.04% cached. Full result in `results-summarise.md`.

## The frontier function was wrong twice, which is worth recording

The first version compared quality and cost, treating any difference as a difference. It reported the box as
dominated by gemma-4 — on a quality gap of 1.4 points at p = 0.597 and a cost gap of 8% where gemma-4's
price is a **placeholder**, while the box answers nine times faster. Every leg of that was an artifact.

Domination now requires each leg to be real: an *advantage* on quality must be significant, a
`pricing_placeholder` price may never displace a measured one, and latency is a third axis rather than
something the frontier silently discards.

The fix then broke it the other way, and the failure is instructive. Requiring significance for the
"not worse" direction too meant reading **"not proven worse" as "not worse"**, and a cheap fast layer at
0.923 was reported as dominating the best layer at 0.980 purely because their difference was not
significant. So the rule is asymmetric on purpose: **the point estimate must not be worse, and a claimed
advantage must be significant.**
