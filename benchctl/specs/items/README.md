# Canary items

## classification-ja-public-v1.jsonl

48 Japanese review sentences from `tyqiangz/multilingual-sentiments` (config `japanese`, split `test`),
stratified 8 per (length bin, label) over two length bins and three labels. Built by
`scripts/fetch_canary_classification.py`, which spreads its offsets across the whole split because the
first few hundred rows are a single label — read from the front, the set arrives with two of three
classes missing, which is a canary that cannot detect the failure mode it exists to detect.

**This is a public dataset, not held-out production traffic.** `p_i` is defined on the traffic the box
would actually serve, so the rate this yields proves the path and is not admissible evidence for
routing. Re-measure on real traffic before admitting anything on it.

### What the first run showed about the items

Measured 2026-08-27, Qwen3.6-35B-A3B on the box against `claude-haiku-4-5`, 48 items each:

| | box | haiku |
| --- | --- | --- |
| passed | 38/48 = 0.792 | 36/48 = 0.750 |
| cost | $0.00279 (at full occupancy) | $0.01620 |

Paired: two items the box got and haiku did not, none the other way, so the difference is +4.2 points
with a one-sided 80% lower bound of +2.1 — non-inferior at a 2-point margin, and in fact ahead.

**But every single miss on both layers was `ニュートラル`.** Positive and negative were perfect on both.
The labels here are star ratings rather than sentiment judgements, and a three-star review is genuinely
ambiguous, so this suite partly measures "can you guess a rating bucket". Two consequences:

* the absolute rate describes the task definition more than the layers, and should not be quoted as
  either layer's classification accuracy;
* the paired difference survives, because both layers saw the same prompt and the same items — which is
  the reason admission is decided on the paired statistic and not on the rate.

A stronger version of this family would use two classes, or ground truth that is a judgement rather than
a rating. That is the change to make before this suite is used for anything but plumbing.
