"""Grading, delegated to the upstream benchmark's own scorer.

Answer extraction is where a grader quietly becomes a model-preference: a
model that says "The answer is B." and one that says "B" are equally right, and
a parser that only accepts one of them converts style into accuracy. So the
extraction and the comparison both come from the upstream suite, unchanged, and
every arm is graded by the same code.

What this module adds is the audit. `unparsed` is tracked separately from
`incorrect`, because a per-model parse failure rate that differs across members
means the accuracy comparison is contaminated and has to be fixed before the
numbers mean anything.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path


def _ensure_upstream_on_path(bench_root: Path | None = None) -> None:
    """Put the upstream `bench/` directory on sys.path.

    Located by environment variable rather than a relative walk: the upstream
    checkout is not inside this repository, and guessing at `../../semantic-router`
    would break the moment someone clones it elsewhere.
    """
    import os

    root = bench_root or Path(
        os.environ.get("VSR_BENCH_ROOT", "")
    )
    if not str(root):
        raise RuntimeError(
            "VSR_BENCH_ROOT must point at the upstream semantic-router bench/ "
            "directory, which supplies the datasets and the scorer"
        )
    if not (root / "reasoning").is_dir():
        raise RuntimeError(f"{root} does not look like the upstream bench/ directory")
    if str(root) not in sys.path:
        sys.path.insert(0, str(root))


@dataclass(frozen=True)
class Grade:
    extracted: str | None
    correct: bool
    parsed: bool


def grade(text: str | None, question: object, bench_root: Path | None = None) -> Grade:
    """Grade one answer with the upstream extractor and comparator."""
    _ensure_upstream_on_path(bench_root)
    from reasoning.reasoning_mode_eval import _is_correct_answer
    from reasoning.router_reason_bench_multi_dataset import extract_answer

    if text is None:
        return Grade(extracted=None, correct=False, parsed=False)
    extracted = extract_answer(text, question)
    if extracted is None:
        return Grade(extracted=None, correct=False, parsed=False)
    return Grade(
        extracted=extracted,
        correct=bool(_is_correct_answer(question, extracted)),
        parsed=True,
    )


def guessing_union_accuracy(n_members: int, n_options: int) -> float:
    """Chance that at least one of N independent guessers is right.

    Reported next to any existential upper bound over a multiple-choice set. An
    "at least one member was correct" bound rises with pool size even when no
    member knows anything, and this is the number that says how much of it is
    the pool and how much is the format.
    """
    return 1.0 - (1.0 - 1.0 / n_options) ** n_members
