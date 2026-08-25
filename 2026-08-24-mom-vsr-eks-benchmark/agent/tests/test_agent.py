"""Tests for the parts of the episode harness that decide what counts as success.

The network and the container are not tested here. What is tested is the subset the run
covers and the rules that decide a verdict, because a mistake in either produces a number
that looks like a model result and is not one.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

AGENT = Path(__file__).resolve().parents[1]
if str(AGENT) not in sys.path:
    sys.path.insert(0, str(AGENT))

import dataset  # noqa: E402
import score  # noqa: E402


def instance(instance_id: str, repo: str, difficulty: str) -> dataset.Instance:
    return dataset.Instance(
        instance_id=instance_id,
        repo=repo,
        base_commit="abc123",
        environment_setup_commit="def456",
        problem_statement="something is wrong",
        difficulty=difficulty,
        fail_to_pass=("t::a",),
        pass_to_pass=("t::b",),
        gold_patch="",
        test_patch="",
    )


def corpus() -> list[dataset.Instance]:
    """A corpus shaped like the real one: one repository dominating it."""
    out = [instance(f"django__django-{i}", "django/django", "<15 min fix") for i in range(40)]
    out += [instance(f"sympy__sympy-{i}", "sympy/sympy", "15 min - 1 hour") for i in range(10)]
    out += [instance("flask__flask-1", "pallets/flask", "1-4 hours")]
    out += [instance("seaborn__seaborn-1", "mwaskom/seaborn", ">4 hours")]
    return out


class TestSubset:
    def test_the_dominant_repository_does_not_take_the_subset(self):
        """Proportional sampling would give Django 78% of it and answer a different question."""
        picked = dataset.stratified(corpus(), size=8)
        shares = {}
        for i in picked:
            shares[i.repo] = shares.get(i.repo, 0) + 1
        assert shares["django/django"] <= 3
        assert len(shares) >= 3

    def test_every_difficulty_present_when_the_size_allows(self):
        picked = dataset.stratified(corpus(), size=8)
        assert len({i.difficulty for i in picked}) == 4

    def test_the_same_seed_gives_the_same_subset(self):
        a = dataset.stratified(corpus(), size=10, seed=7)
        b = dataset.stratified(corpus(), size=10, seed=7)
        assert [i.instance_id for i in a] == [i.instance_id for i in b]

    def test_a_different_seed_gives_a_different_one(self):
        a = dataset.stratified(corpus(), size=10, seed=7)
        b = dataset.stratified(corpus(), size=10, seed=8)
        assert [i.instance_id for i in a] != [i.instance_id for i in b]

    def test_asking_for_more_than_exists_returns_what_exists(self):
        picked = dataset.stratified(corpus(), size=1000)
        assert len(picked) == len(corpus())

    def test_the_image_name_follows_the_upstream_convention(self):
        """SWE-bench's images spell a double underscore as _1776_."""
        assert instance("psf__requests-1142", "psf/requests", "<15 min fix").image == (
            "swebench/sweb.eval.x86_64.psf_1776_requests-1142:latest"
        )


class TestCheatDetection:
    """An agent that edits a test file has changed its own examiner."""

    @pytest.mark.parametrize(
        "path",
        [
            "test_requests.py",
            "tests/test_models.py",
            "django/tests/regressiontests/test_x.py",
            "src/testing/test_helper.py",
        ],
    )
    def test_a_test_file_is_detected(self, path):
        diff = f"diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@\n-a\n+b\n"
        assert score.touched_tests(diff) == [path]

    @pytest.mark.parametrize(
        "path", ["requests/models.py", "django/db/models/query.py", "src/latest.py"]
    )
    def test_source_files_are_left_alone(self, path):
        diff = f"diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@\n-a\n+b\n"
        assert score.touched_tests(diff) == []

    def test_a_patch_touching_both_is_still_caught(self):
        diff = (
            "diff --git a/requests/models.py b/requests/models.py\n"
            "--- a/requests/models.py\n+++ b/requests/models.py\n@@\n-a\n+b\n"
            "diff --git a/tests/test_models.py b/tests/test_models.py\n"
            "--- a/tests/test_models.py\n+++ b/tests/test_models.py\n@@\n-a\n+b\n"
        )
        assert score.touched_tests(diff) == ["tests/test_models.py"]


class TestOutcomeReading:
    def test_no_tests_named_is_not_a_pass_by_accident(self):
        """An instance with an empty list must not read as a green run."""
        outcome = score.pytest_outcome((), timeout=1)
        assert outcome["ran"] == 0 and outcome["detail"] == "no tests named"
