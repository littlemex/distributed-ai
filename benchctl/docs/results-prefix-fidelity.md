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
traffic — not that its quality equals the APIs'. Separating them needs a harder version: more facts, distractor
facts that nearly match, a longer preamble, more turns.

## The control that made it mean something, and the difference it found

Run again with the facts **removed** from the preamble and every layer drops to 0% content, which is what
licenses the 100% above: the layers were retrieving, not inferring the answer from the question. Without that
control the whole run would have been worthless.

It also found the one real difference between the layers, and it is not in the column the run was watching:

| layer | format on the unanswerable control | what it emitted |
| --- | --- | --- |
| **box-qwen36-tp2x2** | **83.3%** | a well-formed, invented token — `ZR-6585` where the absent fact was `ZR-6584` |
| api-gemma-4 | 0.0% | `unknown`, `<module-01>` |
| api-haiku-4-5 | 0.0% | `UNKNOWN`, `not provided in document` |

**Asked for something that is not in the context, the box invents a plausible answer and the two APIs say they
do not know.** Twelve turns out of twelve on each layer, unanimous in both directions. The box's *higher* format
score here is the signal: it kept obeying the output contract and filled the slot with a fabrication, while the
APIs broke the format in order to refuse.

The off-by-one is worth staring at. The absent token was `ZR-6584` and the box produced `ZR-6585`. It is
reconstructing the shape of an answer from the shape of the question, which is exactly the failure that a strict
output format makes harder to notice: a downstream system parsing `TAG:` gets a syntactically perfect answer
either way.

That has a routing consequence the cost work does not: **if the traffic can ask about things absent from its
context, the box needs a verifier that the APIs do not.** On this traffic — where every question was
answerable — it costs nothing. On traffic where questions can be unanswerable, the box's failure mode is silent
and the APIs' is loud, and loud is cheaper to handle.

## What this does not say

**Twelve turns per layer on the control.** The refusal behaviour is unanimous but the sample is small, and it is
one prompt shape and one output contract. A layer told explicitly "answer UNKNOWN if the token is absent" might
behave differently, and that instruction was deliberately not given — the point was what happens when nobody
thought to give it.

**Saturation is a limitation, not a result.** All three layers at 100% means the task was too easy to rank them,
and the harder version has not been run.

**No claim about anything but these two properties.** This measures instruction retention and prefix retrieval.
It does not measure whether the box's prose, reasoning or tool use are as good, on this traffic or any other.

**One prompt, one seed per conversation, temperature 0.** Determinism was not checked here; the cache-hit
equivalence question is measured separately in `cache_equivalence.py`, which found 22 of 22 cache-hit pairs
identical.
