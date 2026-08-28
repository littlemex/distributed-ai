"""Long-document summarisation, scored on facts kept and facts invented, without a judge.

The family an advisor named as the box's second candidate to win, and the reasoning is structural rather
than hopeful: a single-shot summary of a long document has a long prefill and **no prefix reuse**, so the
API's cache discount — the thing that made the box 1.76x more expensive on agentic traffic — does not
apply. On the agentic family the box was 3.0x *cheaper* than the same API with caching switched off, and
this family is that regime by construction.

Scoring deliberately avoids an LLM judge, on both advisors' advice, and measures two things separately:

* **Key-fact recall.** Atoms are extracted from the *reference* summary — numbers, money, percentages,
  years, acronyms and multi-word proper nouns — and the score is the fraction present in the candidate.
  This is a recall metric and is named as one: it says nothing about whether the summary reads well.
* **Unsupported numbers.** Numbers in the candidate that no number in the source document can account for.
  A fabricated figure is the failure mode that matters most in a summary and it is mechanically detectable,
  so there is no excuse for measuring only recall.

## The thresholds are pinned by controls, because the first version of them was inverted

The first version required *zero* unsupported numbers by exact string match, and set the recall floor at
0.30. Scoring three controls with it, as if each were a model's answer, showed it measuring the opposite
of summarisation:

| control                              | pass rate | recall median | unsupported median |
| ------------------------------------ | --------: | ------------: | -----------------: |
| the gold reference summary itself    |      0.40 |         1.000 |                1.0 |
| the document's own first 300 words   |      0.48 |         0.284 |                0.0 |

The metric's ceiling was 0.40, because a reference summary legitimately writes "$1.4 billion" where the
report says "1,432 million" and exact matching calls that an invention, about 1.2 times per summary. And an
extractive non-summary *outscored the human reference*, because the cheapest way to pass was to write no
numbers of your own, which copied prose does by construction. A layer scored 0.887 on that metric and the
number meant nothing.

So the thresholds here are not chosen. `scripts/calibrate_summarise.py` scores twelve controls and refuses
any setting that cannot keep five of them where they have to be. What each one is for is written there;
what they come out at, at the frozen thresholds, is:

| control                                        |  rate | what it establishes                        |
| ---------------------------------------------- | ----: | ------------------------------------------ |
| best 300-word selection from the reference     |  0.99 | the ceiling: the floor is achievable       |
| the reference truncated at 300 words           |  0.88 | a plain truncation still mostly passes     |
| the reference, paraphrased and rescaled        |  0.89 | matching is not brittle to abstraction     |
| the document's own first 300 words              |  0.16 | an extract is not a summary                |
| a 300-word window from the document's middle    |  0.12 | and that is not a quirk of the lead        |
| every figure multiplied by 1.07                 |  0.04 | fabrication is caught                      |
| another report's reference summary              |  0.00 | the metric is about *this* document        |
| the document's atoms listed without prose       |  0.10 | coverage alone does not pass               |
| the reference with its figures permuted         |  0.88 | **the blind spot, measured**               |

That last row is the honest limit of a metric with no judge in it, and both advisors named it independently
before it was measured: permuting the figures among their slots leaves every atom present and every figure
supported, so nothing here can see that every claim is now false. It is reported at full size rather than
mentioned in passing, because a reader who takes `passed` to mean "faithful" is being misled. It means
carried the atoms, invented no figures, stayed short, and reads as prose.

Two of the gates exist because a control caught something. The prose gate was added when a list of the
document's own entities passed at 0.71 — recall cannot tell coverage from a summary, but grammar can, since
prose spends about 0.36 of its words on function words and a list spends 0.15. And the fabrication rule
became a share of the figures written rather than a flat count once the ceiling's own false-flag rate was
measured: on the human summaries, where every figure is genuinely the document's, this detector still flags
a 95th percentile of 0.333 of them, so the flat budget of three was penalising correct dense summaries
while forgiving a summary that wrote four figures and invented three. The share sits at 0.40 — above that
0.333, far below the 0.857 the fabrication control flags — and the gap is real rather than lucky, because
given figures drawn at random magnitudes the support rule still rejects 7 in 8.

The frozen thresholds are the centre of a region, not a point, and `admissible_thresholds` carries the rest
of it. That matters for the same reason the controls do: `recall_floor` at 0.55 and at 0.60 are both
defensible, so a comparison between layers that holds at one and reverses at the other has not measured
the layers.

## Two traps this design has to avoid, and does

* **Length buys recall.** A longer summary contains more of anything, so the instruction fixes a target
  length, `max_tokens` bounds it, and the actual length is recorded on every verdict. A layer that wins on
  recall while writing twice as much has not won.
* **Copying the document is not summarising.** Recall alone would reward reproducing the input, so the
  compression ratio is recorded too and a candidate longer than a quarter of the source fails outright.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from math import ceil, floor as _floor, log10
from pathlib import Path

from .. import scorers

# Numbers, including money, percentages and years, kept as written so "1,234" and "1234" both normalise.
_NUM = re.compile(r"(?<![\w.])(?:\$\s?)?\d[\d,]*(?:\.\d+)?\s?%?")
# Acronyms of three or more capitals, and runs of capitalised words, which is what a report's entities are.
_ACRONYM = re.compile(r"\b[A-Z]{3,}\b")
_PROPER = re.compile(r"\b(?:[A-Z][a-z]+(?:\s+(?:of|for|and|the))?\s+){1,4}[A-Z][a-z]+\b")

# The rescalings a report and its summary disagree by: thousands, millions, billions, and percent against
# fraction. "1,432 million" and "$1.4 billion" are one figure written twice, and a metric that calls the
# second one an invention is measuring prose style.
_SCALES = (1.0, 1e2, 1e-2, 1e3, 1e-3, 1e6, 1e-6, 1e9, 1e-9)

# "Department of Homeland Security (DHS)" — a report introduces its entities this way, and the summary is
# then free to use either form. Matching the expansion by substring alone would score an abstractive layer
# down for using the abbreviation the document itself defined: the same defect the scale tolerance above
# fixes for figures, which is why it is fixed here too rather than left to the reader of the results.
_ALIAS_DEF = re.compile(r"([A-Z][\w'&.\-]*(?:\s+(?:of|for|and|the|[A-Z][\w'&.\-]*)){0,5})"
                        r"\s*\(([A-Z]{2,})[,)]")

# Recall alone cannot tell a summary from a list of the document's entities, and a control that does
# exactly that passed at 0.71. What separates them is not content but grammar: prose spends a third of its
# words on function words and a list spends almost none, so this is the cheapest honest check that the
# candidate is a summary rather than the coverage that a summary would have had.
_FUNCTION_WORDS = frozenset("""
a an the and or but if while of to in on at by for with from as that which who whom whose this these those
is are was were be been being has have had do does did not no nor than then so such it its their his her
they them we our you your he she i also more most other some any each both between into through during
after before above below over under again further once here there when where why how all only own same
about against because can could may might must shall should will would upon within without
""".split())


def _function_word_rate(text: str) -> float | None:
    words = re.findall(r"[A-Za-z']+", text.casefold())
    if len(words) < 20:
        return None
    return sum(1 for w in words if w in _FUNCTION_WORDS) / len(words)


def _norm_number(s: str) -> str:
    return re.sub(r"[\s,$]", "", s).rstrip("%").rstrip(".")


def _numbers(text: str) -> list[float]:
    out: list[float] = []
    for match in _NUM.findall(text):
        try:
            out.append(float(_norm_number(match)))
        except ValueError:
            continue
    return out


def _significant_digits(x: float) -> int:
    """How precisely a figure was written, which is the precision any comparison to it may assume."""
    digits = re.sub(r"[-.]|0+$", "", repr(float(x)).split("e")[0]).lstrip("0")
    return len(digits) or 1


def _round_to(x: float, digits: int) -> float:
    if x == 0:
        return 0.0
    return round(x, -(_floor(log10(abs(x))) - digits + 1))


def _accounts_for(written: float, source: float) -> bool:
    """Could `source` be the figure that `written` is reporting?

    Precision comes from `written`, because that is the claim being checked: a summary that says "1.4
    billion" has asserted two significant digits and is entitled to be judged on two. Used in both
    directions — to ask whether a candidate carried a reference's figure, and whether the document can
    account for a candidate's figure — since both are the same question about one written number.
    """
    digits = _significant_digits(written)
    for scale in _SCALES:
        target = written * scale
        if source == target or _round_to(source, digits) == _round_to(target, digits):
            return True
    return False


def _aliases(document: str) -> dict[str, set[str]]:
    """The surface forms the document itself declares equivalent, keyed by casefolded form."""
    out: dict[str, set[str]] = {}
    for expansion, acronym in _ALIAS_DEF.findall(document):
        a, b = expansion.strip().casefold(), acronym.casefold()
        if len(a) < 4 or a == b:
            continue
        out.setdefault(a, set()).add(b)
        out.setdefault(b, set()).add(a)
    return out


def _carried(atom: str, candidate_lower: str, aliases: dict[str, set[str]]) -> bool:
    """Whether a non-numeric atom appears in the candidate, in any form the document declared equal."""
    probe = atom.casefold()
    if probe in candidate_lower:
        return True
    return any(alt in candidate_lower for alt in aliases.get(probe, ()))


def _atoms(text: str) -> dict[str, list[str]]:
    """The checkable facts in a piece of text: numbers, acronyms, proper names."""
    numbers = sorted({_norm_number(m) for m in _NUM.findall(text) if _norm_number(m)})
    acronyms = sorted({m for m in _ACRONYM.findall(text)})
    proper = sorted({m.strip() for m in _PROPER.findall(text) if len(m.strip()) > 6})
    return {"numbers": numbers, "acronyms": acronyms, "proper": proper}


@dataclass(frozen=True)
class Item:
    id: str
    document: str
    reference: str
    doc_chars: int
    length_bin: int | None = None


PROMPT = ("Summarise the report below in at most {target} words.\n"
          "Keep every specific figure, date, agency name and acronym that matters. "
          "Do not introduce any number that is not in the report.\n\n"
          "REPORT:\n{document}\n\nSUMMARY:")


class SummariseFacts:
    """One family: long documents, a reference summary, and mechanical fact scoring."""

    name = "tasks.summarise_facts"

    max_tokens = 700              # about 450 words, comfortably above the 300-word target
    target_words = 300
    recall_floor = 0.55           # calibrated: separates the reference from an extract of the document
    unsupported_grace = 1         # below this a share is meaningless, so one is forgiven outright
    unsupported_dense_n = 4       # and a share is only computed once the summary wrote this many numbers
    unsupported_share = 0.40      # above the ceiling's own false-flag rate, far below a fabrication's
    max_compression = 0.25        # a "summary" longer than this fraction of the source is not one
    min_function_word_rate = 0.20  # below this it is a list of the document's atoms, not prose

    # Every cell of the threshold grid where all five gated controls still hold. The frozen values above
    # are its centre, and they are not special: the calibration cannot tell these cells apart, so an
    # admission decision is reported at all of them. One that flips inside this region is an artefact of
    # where the threshold was put, and `benchctl score --score-version` prints that rather than hiding it.
    admissible_thresholds = tuple(
        {"recall_floor": floor, "unsupported_grace": grace, "unsupported_share": share}
        for floor in (0.55, 0.60)
        for grace, share in ((1, 0.35), (1, 0.40), (2, 0.50), (1, 0.60))
    )

    def __init__(self, items_path: Path) -> None:
        self.items_path = Path(items_path)

    def load(self, limit: int | None = None) -> list[Item]:
        out: list[Item] = []
        for line in self.items_path.read_text().split("\n"):
            if not line.strip():
                continue
            raw = json.loads(line)
            out.append(Item(id=str(raw["id"]), document=raw["document"],
                            reference=raw["reference"], doc_chars=len(raw["document"]),
                            length_bin=raw.get("length_bin")))
            if limit and len(out) >= limit:
                break
        return out

    def prompt(self, item: Item) -> str:
        return PROMPT.format(target=self.target_words, document=item.document)

    def measure(self, item: Item, answer: str | None) -> dict:
        """The continuous measurements, with no threshold applied.

        Separate from `score` because the thresholds are the part under calibration and the measurements
        are not: the admission decision is reported over a band of thresholds, which means the same
        response has to be re-thresholded many times without being re-measured.
        """
        cand = answer or ""
        ref_atoms = _atoms(item.reference)
        cand_lower = cand.casefold()
        cand_numbers = _numbers(cand)
        doc_numbers = _numbers(item.document)
        aliases = _aliases(item.document)

        numeric = ref_atoms["numbers"]
        wanted = numeric + ref_atoms["acronyms"] + ref_atoms["proper"]
        found, found_numeric = [], 0
        for atom in wanted:
            if atom in numeric:
                try:
                    value = float(atom)
                except ValueError:
                    hit = _carried(atom, cand_lower, aliases)
                else:
                    hit = any(_accounts_for(c, value) for c in cand_numbers)
                found_numeric += bool(hit)
            else:
                hit = _carried(atom, cand_lower, aliases)
            if hit:
                found.append(atom)

        # A number in the summary that nothing in the source can account for. The one failure mode worth
        # catching mechanically, and the reason recall alone is not enough.
        unsupported = sorted({c for c in cand_numbers
                              if not any(_accounts_for(c, d) for d in doc_numbers)})
        return {
            "key_fact_recall": (len(found) / len(wanted)) if wanted else None,
            "numeric_recall": (found_numeric / len(numeric)) if numeric else None,
            "atoms_wanted": len(wanted), "atoms_found": len(found),
            "unsupported_numbers": [f"{u:g}" for u in unsupported[:8]],
            "unsupported_count": len(unsupported),
            "numbers_emitted": len(set(cand_numbers)),
            "function_word_rate": _function_word_rate(cand),
            "summary_chars": len(cand), "document_chars": item.doc_chars,
            "compression": (len(cand) / item.doc_chars) if item.doc_chars else None,
        }

    def fabricates(self, unsupported: int, written: int) -> bool:
        """Whether this many unexplainable numbers, out of this many written, is fabrication.

        A share rather than a count, because a count shelters the exploit the recall floor was added to
        close: three unexplainable numbers out of four written is a summary that invents, and three out of
        thirty is a detector that cannot follow three roundings, and a flat budget of three calls them the
        same thing. One is forgiven outright because a share over two numbers means nothing, and the share
        is only consulted once the summary wrote enough numbers for it to.

        The threshold is bounded on both sides by measurement, not taste. On the ceiling control — the human
        summary, where every figure is genuinely the document's — this detector still flags a 95th
        percentile of 0.333 of the numbers written, so anything below that penalises correct summaries. On
        the fabrication control, where every figure is wrong, it flags a 5th percentile of 0.857. The
        threshold has to live in that gap and is set near its lower edge, which favours letting a real
        summary through over catching a marginal invention. The gap exists at all only because the support
        rule is not vacuous: given random figures at random magnitudes it still rejects 7 in 8.
        """
        if unsupported <= self.unsupported_grace:
            return False
        if written >= self.unsupported_dense_n:
            return unsupported / written > self.unsupported_share
        return True

    def verdict_reasons(self, measured: dict) -> list[str]:
        """Why this measurement fails admission, at the currently frozen thresholds."""
        reasons = []
        recall = measured["key_fact_recall"]
        if recall is None:
            reasons.append("reference carried no checkable atoms")
        elif recall < self.recall_floor:
            reasons.append(f"recall {recall:.2f} below floor {self.recall_floor}")
        unsupported, written = measured["unsupported_count"], measured["numbers_emitted"]
        if self.fabricates(unsupported, written):
            reasons.append(f"{unsupported} of {written} numbers written are unsupported")
        compression = measured["compression"]
        if compression is not None and compression > self.max_compression:
            reasons.append(f"compression {compression:.2f} above {self.max_compression}")
        prose = measured["function_word_rate"]
        if prose is None:
            reasons.append("too short to be prose")
        elif prose < self.min_function_word_rate:
            reasons.append(f"function-word rate {prose:.2f} below {self.min_function_word_rate}: "
                           f"a list of the document's entities, not a summary")
        return reasons

    def score(self, item: Item, answer: str | None) -> scorers.Verdict:
        measured = self.measure(item, answer)
        reasons = self.verdict_reasons(measured)
        return scorers.Verdict(
            item_id=item.id, passed=not reasons and measured["key_fact_recall"] is not None,
            predicted=(answer or "")[:300],
            expected=f"{measured['atoms_wanted']} atoms from the reference",
            detail=json.dumps(measured | {"failed_because": reasons}, ensure_ascii=False),
        )
