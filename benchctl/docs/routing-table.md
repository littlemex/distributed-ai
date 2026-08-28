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

A snapshot lives at `specs/routing-table.json`: one suite, `ocrbench-stratified-278`, 278 items, and the
layers merged so far. On the items every merged layer answered:

| layer | rate | $/1k items | latency p50 | frontier |
| --- | --- | --- | --- | --- |
| api-sonnet-5 | 0.980 | $1.047 | 2.61 s | **yes** |
| api-opus-5 | 0.970 | $7.733 | 1.99 s | no, dominated by sonnet-5 |
| box-qwen36-tp2x2 | 0.919 | **$0.117** | **0.11 s** | **yes** |
| api-gpt-5.6-terra | 0.919 | $1.850 | 1.77 s | no, dominated by the box |
| api-haiku-4-5 | 0.803 | $0.311 | 1.26 s | no, dominated by the box |

Every pair crosses, so **escalation cannot reach the union anywhere in this family** — recorded as
`escalation_can_reach_union: false` on every pair, which is a fact a router should read rather than a
preference someone expressed.

`gpt-5.6-terra` is the clearest argument for the table's existence: it ties the box exactly on the common
set and is dominated by it anyway, at sixteen times the cost and sixteen times the latency. A table of
accuracy alone would have called them equivalent; a table of accuracy and price would have missed that the
box also answers sixteen times faster.

Merging it also corrected a conclusion the previous page had stated too strongly. The Anthropic layers each
refused 39 document-heavy images with `request_too_large`, which had been written up as "these cannot be
served by an API at any price". terra refused **none** of them. The 200,000-character cap belongs to the
gateway's Anthropic route, not to the gateway, so it is a **per-layer route constraint** — which is why the
table buckets exclusions by cause on the layer rather than recording a count on the suite.
