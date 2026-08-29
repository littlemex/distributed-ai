# A cached prefix still steers the model, and the box invents an answer where the APIs refuse

Measured 2026-08-29 by `benchctl/prefix_fidelity.py`. Box through the restored affinity router with a stable
`X-Correlation-ID`; `gemma-4` and `claude-haiku-4-5` through the gateway. Five conversations of six turns each,
a 12,000-token shared preamble carrying six planted facts, one fact asked per turn, 200 output tokens. Thirty
graded turns per layer, plus twelve on the control.

## Why this run exists

The routing rule says to send prefill-heavy prefix-reusing traffic to the box above about 8,000 requests an
hour. That is entirely a cost argument, and the traffic it applies to was **the one family with no quality
number at all**. Recommending a layer on price without checking what it produces there is a gap, and both
advisors named it.

The failure worth hunting is specific rather than general. A conversation's later turns are 80–90% cache reads,
so the two things that could quietly break are whether turn 1's instruction still holds at turn 6, and whether
the model still reads a preamble that is no longer being recomputed. Each turn therefore asks for one planted
fact and requires it in a fixed line, `TAG: <token>`, with format and content scored separately: a layer that
stops emitting the line has forgotten the instruction, and one that emits it with the wrong token has stopped
reading.

## The scorer, pinned before any layer was scored

| control | format | content |
| --- | --- | --- |
| a scripted reply that follows the rule | 1.00 | 1.00 |
| a fluent reply with no tag line | 0.00 | 0.00 |
| the tag line with a wrong token | 1.00 | 0.00 |

The third row is the one that matters: format passes while content fails, which is what proves the two are
separable rather than one measurement reported twice.

## The result: the failure does not happen

| layer | planted | turns | cached | format | content | content after turn 1 |
| --- | --- | --- | --- | --- | --- | --- |
| box-qwen36-tp2x2 | yes | 30 | 79.1% | 100% | **100%** | 100% |
| api-gemma-4 | yes | 30 | 11.0% | 100% | **100%** | 100% |
| api-haiku-4-5 | yes | 30 | 0.0% | 100% | **100%** | 100% |

By turn, for all three layers: 1.00 at every one of the six. **No instruction decay, no retrieval failure, and
no difference between the layers.** The box held 100% with 79% of its prompt served from cache, which is the
specific thing this run was built to doubt, and it does not happen.

**The task saturated, so read that as a bound rather than a ranking.** Three layers at 100% cannot be ordered.
What this establishes is that instruction retention and prefix retrieval are not where the box loses on this
traffic — not that its quality equals the APIs'.

### The harder version also saturates, which settles the axis

So it was made harder: **24,000-token preamble, twelve facts, ten turns**, and a **decoy** planted next to each
real fact — a "superseded" token one character away, placed *before* the real line, so reading the first match
that looks like an answer is the wrong answer.

| layer | turns | cached | format | content | took the decoy |
| --- | --- | --- | --- | --- | --- |
| box-qwen36-tp2x2 | 50 | 87.7% | 100% | **100%** | 0.0% |
| api-gemma-4 | 50 | 2.8% | 100% | **100%** | 0.0% |
| api-haiku-4-5 | 50 | 0.0% | 100% | **100%** | 0.0% |

Content is 1.00 at every one of the ten turns on all three layers, and **not one answer took a decoy**. The box
held that while 87.7% of its prompt came from cache.

Two runs at two difficulties, both at the ceiling, is not a failure to design a hard enough task — it is the
answer. **Retrieving a fact from a 24k shared prefix under an output contract, with an adversarial near-miss
beside it, is not hard for any of these layers, and it does not get harder when the prefix is served from
cache.** This axis is settled and should stop being measured. If the box has a quality problem on this traffic it
is somewhere else: prose, reasoning, tool-call correctness. None of those is measured here and none is
mechanically checkable without a judge, which is why this run chose the two properties it could check honestly
rather than the ones that matter most.

## The control that made it mean something, and the difference it found

Run again with the facts **removed** from the preamble and every layer drops to 0% content, which is what
licenses the 100% above: the layers were retrieving, not inferring the answer from the question. Without that
control the whole run would have been worthless.

It also found the one real difference between the layers, and it is not in the column the run was watching.
The harder run raised the control to **fifty turns per layer**, and it is unambiguous:

| layer | format on the unanswerable control | cached there | what it emitted |
| --- | --- | --- | --- |
| **box-qwen36-tp2x2** | **90.0%** (45 of 50) | 96.3% | a well-formed, invented token — `ZR-6585` where the absent fact was `ZR-6584` |
| api-gemma-4 | 0.0% | 21.5% | `UNKNOWN`, `unknown`, `<module-01>` |
| api-haiku-4-5 | 2.0% (1 of 50) | 0.0% | `UNKNOWN`, `unable to determine - not in document` |

**Asked for something that is not in the context, the box invents a plausible answer forty-five times out of
fifty, and the two APIs refuse essentially always.** The box's *higher* format score here is the signal, not a
credit: it kept obeying the output contract and filled the slot with a fabrication, while the APIs broke the
format in order to refuse. It did so while reading 96.3% of its prompt from cache.

The off-by-one is worth staring at. The absent token was `ZR-6584` and the box produced `ZR-6585`. It is
reconstructing the shape of an answer from the shape of the question, which is exactly the failure that a strict
output format makes harder to notice: a downstream system parsing `TAG:` gets a syntactically perfect answer
either way.

That has a routing consequence the cost work does not: **if the traffic can ask about things absent from its
context, the box needs a verifier that the APIs do not.** On this traffic — where every question was
answerable — it costs nothing. On traffic where questions can be unanswerable, the box's failure mode is silent
and the APIs' is loud, and loud is cheaper to handle.

## Telling it not to guess barely helps

The obvious objection to the row above is that the contract gave the box no sanctioned way to say "not in the
document": refusing meant breaking the output format, and it chose to keep the format. So the run was repeated
with the refusal written into the rule — *"If the build token for that module does not appear in the reference
material above, write exactly `TAG: UNKNOWN` instead. Do not guess a token."*

| layer | unanswerable: refused | still emitted a well-formed token | answerable: correct | answerable: false refusals |
| --- | --- | --- | --- | --- |
| **box-qwen36-tp2x2** | 0% → **24.0%** | 90.0% → **76.0%** | 100% → **100%** | 0% |
| api-gemma-4 | 0% → **100.0%** | 0% → 0% | 100% → 100% | 0% |
| api-haiku-4-5 | 0% → **94.0%** | 2.0% → 6.0% | 100% → 100% | 0% |

**Being told explicitly not to guess moves the box from fabricating 90% of the time to fabricating 76% of the
time.** It takes the offered refusal on 12 of 50 turns. `gemma-4` takes it on all 50 and `claude-haiku-4-5` on
47.

Two things make that a stronger result rather than a weaker one. Nothing regressed on the answerable arm — all
three layers stayed at 100% correct with **zero** false refusals — so offering the escape hatch is free, and the
box simply does not use it. And the caveat this run existed to close is now closed in the unhelpful direction:
**prompt engineering is not a substitute for the verifier.** A rule that says "do not guess" is followed by the
box one time in four.

Checking what the fabrications actually were mattered, because the control has a known imperfection: the
scripted assistant turns carry real tokens, so on the unanswerable arm the *previous* turn's answer is visible in
the history even though the asked token is absent everywhere. Of the box's 38 well-formed wrong answers, **31
(81.6%) are tokens that appear nowhere at all** — genuinely invented — and 7 (18.4%) are copies of a token
visible in the history. So the fabrication reading holds for four fifths of them, and the remaining fifth is a
different failure with the same operational consequence: a syntactically perfect wrong answer.

## What this does not say

**Fifty turns per layer on the control, one prompt shape, one output contract.** The refusal difference is
strong enough at that n to act on. The obvious mitigation — telling the layer it may refuse — was measured and
recovers 24 points of the box's 90, which is the section above.

**The unanswerable control is not perfectly clean.** The scripted assistant turns carry real tokens, so the
previous turn's answer is visible in the history while the asked token is absent. That was quantified rather
than argued away: 18.4% of the box's well-formed wrong answers are history copies and 81.6% appear nowhere. A
cleaner control would script the assistant turns with placeholders, and would raise the invented share rather
than lower it.

**Saturation at both difficulties is a result, not a limitation.** It says this axis does not separate these
layers rather than that the task was badly chosen, and the useful consequence is to stop measuring it.

**No claim about anything but these two properties.** This measures instruction retention and prefix retrieval.
It does not measure whether the box's prose, reasoning or tool use are as good, on this traffic or any other.

**One prompt, one seed per conversation, temperature 0.** Determinism was not checked here; the cache-hit
equivalence question is measured separately in `cache_equivalence.py`, which found 22 of 22 cache-hit pairs
identical.
