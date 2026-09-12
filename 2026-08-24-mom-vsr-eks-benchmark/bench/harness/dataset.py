"""Questions, and the split that keeps a policy honest.

Loading and answer formatting come from the upstream benchmark package
(`vllm-semantic-router-bench`), so the questions are the ones the project's own
suite asks and the prompt is the one it asks them with.

What this module adds is the split. A policy fitted on the same questions it is
scored on will win by memorising them, so every question is assigned to exactly
one of three folds by hashing its id:

    calibration   measure each member per domain; fit the routing policy
    validation    choose the policy's free parameters (top-k, weights)
    test          score once, with the policy frozen

The assignment is a pure function of the question id and a salt, so it needs no
manifest file to be reproducible and cannot drift between a calibration run and
a test run weeks apart. Recording a sampled id list instead would let the two
runs disagree silently.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Iterable, Sequence

CALIBRATION = "calibration"
VALIDATION = "validation"
TEST = "test"

# Cumulative upper bounds over a 0-99 hash bucket, so the widths are 35 / 15 / 50.
# Test is the largest because it carries the only numbers that get reported;
# calibration only has to rank members, and validation only has to choose a
# handful of free parameters.
FOLD_BOUNDS = ((CALIBRATION, 35), (VALIDATION, 50), (TEST, 100))

DEFAULT_SALT = "mom-bench/v1"


def fold_of(question_id: str, salt: str = DEFAULT_SALT) -> str:
    """Which fold a question belongs to. Deterministic, manifest-free."""
    digest = hashlib.sha256(f"{salt}:{question_id}".encode()).digest()
    bucket = int.from_bytes(digest[:8], "big") % 100
    for name, upper in FOLD_BOUNDS:
        if bucket < upper:
            return name
    raise AssertionError("fold bounds must end at 100")


@dataclass(frozen=True)
class Item:
    """One question, with everything the runner and the scorer need."""

    question_id: str
    dataset: str
    category: str
    fold: str
    prompt: str
    # The upstream Question object, kept whole so the upstream scorer can grade
    # against the same structure it was written for.
    question: object


def load_items(
    dataset_name: str,
    *,
    categories: Sequence[str] | None = None,
    samples_per_category: int | None = None,
    seed: int = 42,
    salt: str = DEFAULT_SALT,
    prompt_style: str = "plain",
) -> list[Item]:
    """Load a dataset through the upstream factory and assign folds.

    Raising `samples_per_category` at a fixed `seed` extends the set rather than
    reshuffling it: upstream samples by taking the first n of a seeded
    permutation, so the smaller draw is a subset of the larger one (verified for
    200 against 300). Together with fold assignment by hash, that means a run can
    be made larger later and `--resume` pays only for the questions that are new.
    """
    from reasoning.dataset_factory import DatasetFactory

    dataset = DatasetFactory.create_dataset(dataset_name)
    questions, _info = dataset.load_dataset(
        categories=list(categories) if categories else None,
        samples_per_category=samples_per_category,
        seed=seed,
    )
    items = []
    for question in questions:
        items.append(
            Item(
                question_id=str(question.question_id),
                dataset=dataset.dataset_name,
                category=question.category,
                fold=fold_of(str(question.question_id), salt),
                prompt=dataset.format_prompt(question, prompt_style=prompt_style),
                question=question,
            )
        )
    return items


def in_fold(items: Iterable[Item], fold: str) -> list[Item]:
    return [item for item in items if item.fold == fold]


def fold_counts(items: Iterable[Item]) -> dict[str, dict[str, int]]:
    """Per-category counts per fold, so a thin cell is visible before a run."""
    counts: dict[str, dict[str, int]] = {}
    for item in items:
        counts.setdefault(item.category, {}).setdefault(item.fold, 0)
        counts[item.category][item.fold] += 1
    return counts
