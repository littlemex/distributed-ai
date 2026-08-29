# Translation: measured the scorer, cut the family, kept the instrument

Decided 2026-08-28, before any layer was spent. Translation was on the roster as a family: en→ja, which is
the direction customers ask about and the only one that moves this benchmark off English. It is not being
built, and the reason is a property of the scorer rather than of the models.

This page exists because a family that was cut is worth as much as one that shipped, and because the
alternative — a chrF number for four layers — would have looked clean.

## What was measured

`google/wmt24pp`, `en-ja_JP`: 998 segments, 960 usable after dropping `is_bad_source` and the canary rows,
170 documents, four domains. The 77 documents with at least 500 source characters were the candidate item
set, with an item being a whole document rather than a sentence: segment-level chrF on one reference swings
several points on reference idiosyncrasy alone, which is wider than the gaps between layers, and both
advisors said so independently.

chrF rather than chrF++, because chrF++'s word n-grams need whitespace and Japanese has none. On
unsegmented Japanese the word component degenerates rather than adding signal.

Every number below is chrF against the post-edited reference, over those 77 documents:

| candidate | median | p10 | min / max |
| --- | --- | --- | --- |
| the other human translation in the dataset | 90.3 | 67.3 | min 49.1 |
| the reference with です・ます made plain | 99.9 | 90.7 | min 81.8 |
| the reference in full-width numerals and パーセント | 97.6 | 93.1 | min 83.4 |
| the reference with kanji written as kana | 99.2 | 97.6 | min 94.0 |
| the reference with Japanese punctuation swapped | 83.0 | 78.7 | min 74.3 |
| **the reference with its polarity flipped** | **97.7** | 95.0 | min 86.8 |
| **the reference with its second half deleted** | **55.3** | 54.8 | max 56.2 |
| the English source copied through | 1.0 | 0.0 | max 7.0 |
| another document's reference | 11.2 | 7.4 | max 16.6 |

Two rows decide it.

**chrF is blind to meaning reversal.** Turning 増加 into 減少, できます into できません, 以上 into 以下 and
前 into 後 — the whole document still correct-looking Japanese, every claim now false — costs **2.3 points**.
This is translation's version of the blind spot the summarisation family reports at 0.88, and it is worse
here, because a mistranslated relation is the failure mode a customer actually cares about. Numbers and
entities can be gated mechanically; negation, modality and direction cannot, by anything without a model in
it, and this family had ruled models out by design.

**Omission and legitimate variation overlap.** A half-deleted translation scores 55.3, and the lowest-scoring
valid alternative translation scores 49.1. No single floor admits every valid alternative and rejects every
truncation. Relaxing to the tenth percentile of alternatives (67.3) against the ninetieth of truncations
(55.6) does leave a region, so a floor near 60 would work — if 67.3 were the real ceiling.

## Why that floor would have been the summarisation bug again

It would not be. `wmt24pp`'s `target` is a **post-edit of** `original_target`, not an independent
translation: the two differ on 524 of 960 segments and score 86.4 against each other at segment level, which
is the signature of light editing rather than two people translating the same text. So 90.3 is where the
metric tops out for near-identical text, not what a good different translation scores. An independent
professional translation lands far lower — an advisor puts en→ja human-vs-human chrF in the 35–55 range, and
nothing in this dataset can check that.

Setting a floor at 60 from a ceiling of 90 that is really the same translation twice is exactly the mistake
that made the summarisation scorer rank an extract of the document above the human summary: a threshold
derived from a ceiling that is not the ceiling. The difference is that this time it is known in advance
rather than after a layer has reported a number.

Establishing the real ceiling needs a second independent professional translation of a held-out set. That is
a commissioning cost, not a compute cost, and until it exists this family cannot be calibrated. Everything
else about it is ready.

## The regime claim the family was also supposed to test, and why it would have misled

Translation was attractive for a second reason: short inputs, so a short prefill, so — the thought went —
the API's prompt-cache discount comes back into play and the box's price advantage should shrink. That
framing is wrong, and it is worth recording because the resulting number would have been misread.

Prompt caching has a **minimum cacheable prefix**. A translation request is an instruction plus a short
source and falls under it, so the discount does not apply at all — and even above the minimum the saving
scales with cached tokens, so a short prefill caps the absolute benefit near zero regardless of hit rate.

A later probe made the point harder than this argument does: on this gateway no Claude model does
shared-prefix caching at *any* length, and `claude-haiku-4-5` returns no cached tokens under any condition at
all (`cache-discount-eligibility.md`). So the discount was never the box's problem on this gateway, and a
family built to demonstrate its absence would have been demonstrating something already true everywhere. The
regimes, with that correction applied:

| traffic | prefill | shared across requests | cache discount |
| --- | --- | --- | --- |
| agentic | long | yes, heavily | assumed large — but measured at zero on this gateway |
| long summarisation | long | no | impossible — measured at 0.04% cached |
| translation | short | partly | impossible, below the minimum |

So translation would have shown the box cheap for a *third* distinct reason, and a reader would have
attributed it to the second. Translation is also decode-heavy, where cost is dominated by output tokens that
are never cacheable and inflate differently per tokeniser, which confounds it further.

## What replaces it

The cache question deserves an instrument rather than a family. Same items, same expected output, two arms:
one prompt below the cacheable minimum, one with a shared preamble above it that every request hits. Quality
held constant by construction, so the cost ratio between the arms **is** the cache effect, isolated.

That answers the question this project exists to answer — when does the API's discount beat the box, and
therefore what should be routed to it — without needing references, a new scorer, or a commissioning pass.
The translation family answers it only accidentally and with three confounds attached.

## What would bring the family back

- A held-out set with a second independent professional translation, which is what makes the ceiling real.
- Or in-domain traffic: if the requests to route are support articles, docs or UI strings rather than news,
  the family should be built on that set from the start, with WMT kept only as a calibration anchor. The
  measurement then routes real requests, and the ceiling can be commissioned for the same set.
- Either way the polarity blind spot stays, and would have to be reported rather than closed.
