# A containment check catches fabrication only where nothing real looks like an answer

Decided 2026-08-29, before building anything. Three kill experiments were run first, on both advisors' insistence,
and the third one changed the answer.

## What was proposed

`results-prefix-fidelity.md` found the box's one real quality defect: asked for a fact absent from its context, it
emits a **well-formed invented token 76% of the time** even when the rule says "do not guess", where `gemma-4`
refuses 100% of the time and `claude-haiku-4-5` 94%. The failure is silent and syntactically perfect — a
downstream parser reading `TAG:` cannot tell it from a correct answer.

The obvious fix: **every token-shaped string in the output must appear verbatim in the request's context, or the
answer is not returned.** On the fixture that is a `grep`.

This project has withdrawn two gates that looked exactly this sound — a summarisation fabrication gate that flagged
legitimate rounding, and a prose gate that rejected correct headed Markdown — so the rule was that no gate gets
built before the experiments that could kill it.

## Kill 1, the arithmetic: does not fire

A fire happens on 62% of unanswerable turns (76% well-formed x 81.6% of those absent from context). If a fire
escalates to an API, the box pays for its own wasted call plus the API's, so there is a base rate at which the
escalation erases the box's margin. Solving for it needs no production data:

| requests/hour | box $/1k | vs gemma-4 | escalation erases the margin at |
| --- | --- | --- | --- |
| 8,329 | $1.827 | 1.07x cheaper | **10.4%** of traffic unanswerable |
| 12,439 | $1.223 | 1.60x cheaper | 60.3% |
| 17,889 | $0.851 | 2.29x cheaper | 91.0% |
| 23,476 | $0.648 | 3.01x cheaper | any rate survives |

And substituting `TAG: UNKNOWN` instead of escalating costs nothing at all — the box call already happened and no
second call is made — so that policy has no crossover. **The verifier is affordable everywhere the box was worth
using**, which is above about 8,000 requests an hour. This kill does not fire.

## Kill 2, the extractor: fires, and defines the scope

An advisor's point was that the regex defining "token-shaped" is where fixture-specificity hides, and that
extractor precision failures become matcher false positives downstream. So the extractor was run over real text,
apart from any matching:

| corpus | characters | `[A-Z]{2}-\d{4}` | `[A-Z]{2,5}-\d{1,6}` |
| --- | --- | --- | --- |
| GovReport, 80 real government documents | 4,004,807 | **0** | **307** |
| benchctl docs, technical English prose | 173,945 | 4 (its own fixture, quoted) | 4 |
| benchctl source, Python | 236,066 | 1 (its own constant) | 1 |

**Widening the grammar by two characters takes it from zero false flags to 307**, and the 307 are exactly what was
predicted: `GAO-19`, `COVID-19`, `MD-715`, `SS-18`. Every one is a legitimate real-world identifier, and several
are ones a model would correctly emit *without* them being in its context, because it knows them.

So the check works, and it works because the identifier is opaque and the grammar is tight. That is not a
property of fabrication; it is a property of the fixture's token format. The honest scope is narrow:

> This detects novel unsupported literals in **designated closed-world extractive fields** — fields whose contract
> is that the value must be copied verbatim from authorised evidence — by requiring verbatim occurrence in that
> evidence. It does not detect an incorrect selection of a value that is present, an unsupported paraphrase, a
> wrong calculation, or fabricated prose. It must not be applied to numbers, quantities, dates, paths, symbols or
> generated code, where inventing a new value is legitimate.

## Kill 3, context density: fires, and it is the one that decides

The sharpest objection was that the fixture is token-**sparse**, which maximises invention because there is nothing
to copy. A rich context offers copyable material, so if fabrication shifts from inventing to copying as density
rises, a containment check catches the failure mode the fixture over-represents and misses the one real traffic
would have — detection would be a *decreasing* function of exactly the contexts worth caring about.

Measured, by planting tokens for 150 unrelated components in the same 24k preamble so the context is dense without
answering anything asked:

| context | turns | box refused | emitted a well-formed token | of those, copied from context | invented | **verifier detection** |
| --- | --- | --- | --- | --- | --- | --- |
| sparse, 0 other tokens | 50 | 24.0% | 76.0% | 0 | 38 | **100.0%** |
| dense, 150 other tokens | 60 | **15.0%** | **85.0%** | **10** | 41 | **80.4%** |

**The objection is confirmed in direction, and the box also behaves worse.** Given material to copy it refuses
less often (24% → 15%), fabricates more often (76% → 85%), and a fifth of its fabrications become copies that a
containment check cannot see. Detection falls from 100% to 80.4% at 150 tokens.

A real agentic context — a repository, a document set, a tool schema — holds far more than 150 identifier-shaped
strings, so detection would fall further. The measurement does not say where it lands, only that the slope is in
the wrong direction.

## The decision

**No production verifier.** Not because it does not work, but because what it detects is bounded by two things
that both move against it: the field must be an opaque identifier under a copy contract, which the extractor test
shows is a narrow surface; and its detection rate decays as the context fills with copyable material, which is
what real contexts do.

What is worth keeping is what the three experiments produced, and it is more useful than the tool would have been:

- **The affordability arithmetic**, so anyone who does build one knows it is free below a 10% unanswerable rate at
  the crossing point and unconditionally free past 23,000 requests an hour.
- **The measured scope boundary** — 0 false flags to 307 on a two-character change — which is the number that
  tells someone whether their field qualifies.
- **The density slope**, which is the reason not to quote a single detection rate for this class of check.
- **A correction to this project's own conclusion.** `results-prefix-fidelity.md` said traffic that can ask about
  absent things "needs a verifier on the box that the APIs do not need". An advisor disagreed and is right:
  `claude-haiku-4-5` still emits a well-formed token on 6% of unanswerable turns. If provenance is a hard
  invariant it applies to the fallback too, and a design that validates only the box leaks at 6%.

## What would bring it back

- Traffic whose answers are genuinely opaque identifiers under a copy contract — a licence key, a build token, a
  ticket id — where the extractor's tight grammar is the real grammar rather than a fixture's.
- Or the prevention route instead of detection: the box is self-hosted, so guided decoding could constrain the
  token after `TAG:` to the union of context-present values plus `UNKNOWN`. That has a trap worth stating, and it
  is the same trap as retrying a fired request: forcing a fabricator to pick a context-present value converts the
  detectable failure into the undetectable one. Prevention that pushes the error into the blind spot is not
  prevention.
