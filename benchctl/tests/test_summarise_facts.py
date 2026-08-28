"""Tests for the summarisation metric, written as the failures it has actually had.

The v1 scorer for this family was inverted — the document's own opening outscored the human reference —
and nothing in the code was wrong. The thresholds had never been asked whether the best possible answer
could satisfy them. `scripts/calibrate_summarise.py` asks that on the real 80 documents, which is where
the answer lives, because the reference summaries' habit of rounding figures is what broke v1 and no
fixture has that habit.

What is left for a unit test is the machinery underneath: the ordering the metric must never lose, and
each tolerance that exists because its absence produced a wrong number once. A synthetic document can
carry those, and they are the things a later edit to a regex would silently break.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from benchctl.tasks.summarise_facts import Item, SummariseFacts  # noqa: E402

# Boilerplate first and the facts later, because that is the shape of the thing being measured: a report's
# opening is not its summary, and a fixture whose first paragraph contains every atom would let an extract
# of the document score a perfect recall — which says something about the fixture, not about the metric.
PREAMBLE = (
    "This report responds to a request from the committee. It describes the scope of the review, the "
    "methodology applied, and the standards under which the work was conducted. The review was performed "
    "in accordance with generally accepted standards, which require that the work be planned and performed "
    "so as to obtain sufficient evidence to provide a reasonable basis for the findings and conclusions. "
) * 8
FACTS = (
    "The Department of Homeland Security (DHS) reported that 1,432 million dollars was obligated in 2023 "
    "for port inspection, an increase of 12.5 percent over the prior year. The Government Accountability "
    "Office (GAO) reviewed 1,234 vessel inspections at 47 ports and found that 318 of them lacked "
    "documentation. The Coast Guard employed 8,750 inspectors during the period, and the agency estimates "
    "that 15,500 containers went unscreened. GAO made 9 recommendations, of which the department "
    "concurred with 7. "
)
DOCUMENT = PREAMBLE + FACTS * 3 + PREAMBLE
REFERENCE = (
    "The Department of Homeland Security obligated 1,432 million dollars in 2023 for port inspection, "
    "12.5 percent more than the prior year. The Government Accountability Office reviewed 1,234 vessel "
    "inspections at 47 ports and found 318 without documentation. The Coast Guard employed 8,750 "
    "inspectors and estimates 15,500 containers went unscreened. GAO made 9 recommendations and the "
    "department concurred with 7 of them."
)


def task() -> SummariseFacts:
    return SummariseFacts.__new__(SummariseFacts)


def item() -> Item:
    return Item(id="t-1", document=DOCUMENT, reference=REFERENCE, doc_chars=len(DOCUMENT))


def measure(answer: str) -> dict:
    return task().measure(item(), answer)


class TestTheOrderingThatMustNotInvert:
    """The reference is the ceiling, and an extract of the document is not a summary.

    This is the whole defect of v1 stated as a test: it had these two the other way round.
    """

    def test_the_reference_outscores_an_extract_of_the_document(self):
        gold = measure(REFERENCE)
        extract = measure(" ".join(DOCUMENT.split()[:120]))
        assert gold["key_fact_recall"] > extract["key_fact_recall"]

    def test_the_reference_passes(self):
        t = task()
        assert not t.verdict_reasons(measure(REFERENCE))

    def test_an_empty_answer_fails_without_raising(self):
        t = task()
        assert t.verdict_reasons(measure(""))
        assert t.score(item(), None).passed is False


class TestFiguresRewrittenAreStillTheSameFigures:
    """Why v1's ceiling was 0.40: a summary rounds and rescales, and that is not invention."""

    def test_a_rescaled_figure_counts_as_carried(self):
        # "1.4 billion" is how a summary writes the document's "1,432 million".
        carried = measure("The department obligated 1.4 billion dollars in 2023, 12.5 percent more.")
        assert carried["numeric_recall"] > 0
        assert carried["unsupported_count"] == 0

    def test_a_figure_from_nowhere_is_unsupported(self):
        assert measure("The department obligated 6,271,904 dollars in 2023.")["unsupported_count"] >= 1

    def test_precision_comes_from_the_candidate_not_the_source(self):
        # Two significant digits asserted, so two are checked: 1.4 billion against 1,432 million passes,
        # and 1.39 billion does not, because three digits were claimed.
        assert measure("obligated 1.4 billion dollars")["unsupported_count"] == 0
        assert measure("obligated 1.39 billion dollars")["unsupported_count"] >= 1


class TestAnAcronymAndItsExpansionAreOneEntity:
    """The same defect as the figures, for names: the document itself declares them equal."""

    def test_the_acronym_carries_an_atom_written_in_full(self):
        full = measure("The Department of Homeland Security obligated funds and the Government "
                       "Accountability Office reviewed inspections at 47 ports.")
        short = measure("DHS obligated funds and GAO reviewed inspections at 47 ports.")
        assert short["atoms_found"] >= full["atoms_found"] - 1

    def test_an_undeclared_abbreviation_does_not_count(self):
        # The document never writes "(TSA)", so nothing licenses it standing for an entity.
        assert measure("TSA reviewed inspections at 47 ports.")["atoms_found"] < \
            measure("The Government Accountability Office reviewed inspections at 47 ports.")["atoms_found"]


class TestFabricationIsAShareNotACount:
    """A flat budget punished dense summaries and forgave sparse inventions."""

    def test_three_inventions_out_of_four_numbers_fails(self):
        t = task()
        assert t.fabricates(unsupported=3, written=4)

    def test_three_out_of_thirty_does_not(self):
        t = task()
        assert not t.fabricates(unsupported=3, written=30)

    def test_one_is_forgiven_because_a_share_over_two_means_nothing(self):
        t = task()
        assert not t.fabricates(unsupported=1, written=2)

    def test_two_out_of_two_is_not_forgiven(self):
        t = task()
        assert t.fabricates(unsupported=2, written=2)


class TestAListOfEntitiesIsNotASummary:
    """Recall cannot tell coverage from a summary. Grammar can, and a control needed it to."""

    def test_atom_soup_fails_on_prose_and_not_on_recall(self):
        soup = "; ".join(["Department of Homeland Security", "Government Accountability Office",
                          "Coast Guard", "1432", "2023", "12.5", "1234", "47", "318", "8750",
                          "15500", "9", "7"] * 4)
        m = measure(soup)
        assert m["function_word_rate"] < SummariseFacts.min_function_word_rate
        assert any("function-word" in r for r in task().verdict_reasons(m))


class TestTheRegionIsARegion:
    """The frozen thresholds are a centre, and the code has to be able to move off them."""

    def test_every_admissible_cell_names_real_attributes(self):
        for cell in SummariseFacts.admissible_thresholds:
            for name in cell:
                assert hasattr(SummariseFacts, name), name

    def test_the_frozen_values_are_inside_the_region(self):
        frozen = {"recall_floor": SummariseFacts.recall_floor,
                  "unsupported_grace": SummariseFacts.unsupported_grace,
                  "unsupported_share": SummariseFacts.unsupported_share}
        assert frozen in [dict(c) for c in SummariseFacts.admissible_thresholds]
