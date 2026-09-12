"""Tests for the parts of the episode harness that decide what counts as success.

The network and the container are not tested here. What is tested is the subset the run
covers and the rules that decide a verdict, because a mistake in either produces a number
that looks like a model result and is not one.
"""

from __future__ import annotations

import shlex
import sys
from pathlib import Path

import pytest

AGENT = Path(__file__).resolve().parents[1]
if str(AGENT) not in sys.path:
    sys.path.insert(0, str(AGENT))

import dataset  # noqa: E402
import score  # noqa: E402
import tools  # noqa: E402


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
        assert outcome["ran"] == 0 and outcome["ok"] is False
        assert "cannot be scored" in outcome["detail"]

class TestColouredOutput:
    """A suite that prints in colour must still be scoreable.

    astropy's own configuration forces colour, so `^PASSED ` matched nothing, the per-test
    count came out zero, and the instance was recorded as one this environment cannot score —
    with 179 of 179 tests passing in the very text that was being searched. The repositories
    with the most opinionated test setup are the ones that would have vanished.
    """

    def outcome(self, monkeypatch, stdout: str, returncode: int = 0) -> dict:
        class Result:
            def __init__(self):
                self.stdout, self.stderr, self.returncode = stdout, "", returncode

        monkeypatch.setattr(score, "run", lambda command, timeout=None: Result())
        return score.pytest_outcome(("a.py::test_one", "a.py::test_two"), timeout=1)

    def test_colour_codes_do_not_hide_the_per_test_lines(self, monkeypatch):
        coloured = (
            "\x1b[32mPASSED\x1b[0m a.py::\x1b[1mtest_one\x1b[0m\n"
            "\x1b[32mPASSED\x1b[0m a.py::\x1b[1mtest_two\x1b[0m\n"
        )
        result = self.outcome(monkeypatch, coloured)
        assert result["basis"] == "per-test lines"
        assert (result["passed"], result["ok"], result["scoreable"]) == (2, True, True)

    def test_a_coloured_failure_is_still_a_failure(self, monkeypatch):
        coloured = (
            "\x1b[32mPASSED\x1b[0m a.py::test_one\n"
            "\x1b[31mFAILED\x1b[0m a.py::test_two\n"
        )
        result = self.outcome(monkeypatch, coloured, returncode=1)
        assert (result["passed"], result["failed"], result["ok"]) == (1, 1, False)

    def test_the_detail_kept_for_the_record_is_readable(self, monkeypatch):
        result = self.outcome(monkeypatch, "\x1b[32mPASSED\x1b[0m a.py::test_one\n")
        assert "\x1b" not in result["detail"]

    def test_colour_is_asked_off_as_well_as_stripped(self, monkeypatch):
        """Stripping is the belt; the flag is the braces, and a suite that respects it keeps
        the recorded output small enough to read."""
        seen = {}

        class Result:
            stdout, stderr, returncode = "PASSED a.py::test_one\n", "", 0

        def fake_run(command, timeout=None):
            seen["command"] = command
            return Result()

        monkeypatch.setattr(score, "run", fake_run)
        score.pytest_outcome(("a.py::test_one",), timeout=1)
        assert "--color=no" in seen["command"]


class TestAwkwardTestIds:
    """A parametrised id is not a shell word.

    astropy names its unit-format tests after the strings they parse, so the ids contain
    spaces, quotes and backslashes. Quoted by hand, 732 of them became fragments pytest could
    not find, the run came back exit 4, and every arm's attempt at the instance was recorded as
    unscoreable — which removes the hardest repositories from the denominator.
    """

    def command_for(self, monkeypatch, tests):
        seen = {}

        class Result:
            stdout = "".join(f"PASSED {t}\n" for t in tests)
            stderr = ""
            returncode = 0

        def fake_run(command, timeout=None):
            seen["command"] = command
            return Result()

        monkeypatch.setattr(score, "run", fake_run)
        outcome = score.pytest_outcome(tuple(tests), timeout=1)
        return seen["command"], outcome

    def test_a_space_inside_the_brackets_survives(self, monkeypatch):
        test_id = "astropy/units/tests/test_format.py::test_powers[-10-1 / 10]"
        command, outcome = self.command_for(monkeypatch, [test_id])
        assert shlex.split(command)[3] == test_id
        assert outcome["ok"]

    def test_a_quote_inside_the_brackets_survives(self, monkeypatch):
        test_id = 'a/b.py::test_unit[m\'s-"x"]'
        command, _ = self.command_for(monkeypatch, [test_id])
        assert shlex.split(command)[3] == test_id

    def test_a_backslash_inside_the_brackets_survives(self, monkeypatch):
        test_id = "a/b.py::test_unicode[\\u212b]"
        command, _ = self.command_for(monkeypatch, [test_id])
        assert shlex.split(command)[3] == test_id

    def test_many_ids_are_all_still_there(self, monkeypatch):
        ids = [f"a/b.py::test_one[case {i} of many]" for i in range(200)]
        command, outcome = self.command_for(monkeypatch, ids)
        assert shlex.split(command)[3:203] == ids
        assert outcome["passed"] == 200


class TestBatching:
    """785 ids do not fit in one command, and the failure arrived after the episode had run.

    Linux caps a single argument at 128 KiB and the whole `bash -lc` script is one argument, so
    xarray's `PASS_TO_PASS` list raised "argument list too long" in the scorer — a finished
    attempt with no verdict, which is indistinguishable from a policy that solved nothing.
    """

    def test_a_short_list_is_one_batch(self):
        assert score._batched(("a", "b", "c")) == [("a", "b", "c")]

    def test_a_long_list_is_split(self):
        ids = tuple(f"tests/test_module.py::test_case_{i}" for i in range(400))
        batches = score._batched(ids, budget=1000)
        assert len(batches) > 1
        assert sum(len(b) for b in batches) == len(ids)
        assert [i for b in batches for i in b] == list(ids)

    def test_no_batch_exceeds_the_budget(self):
        ids = tuple("x" * 50 for _ in range(100))
        for batch in score._batched(ids, budget=200):
            assert len(" ".join(batch)) <= 200

    def test_one_id_larger_than_the_budget_is_still_attempted(self):
        """Refusing it would drop the instance; the runner is allowed to be the one to fail."""
        assert score._batched(("x" * 500,), budget=100) == (("x" * 500,),) or score._batched(
            ("x" * 500,), budget=100
        ) == [("x" * 500,)]

    def test_the_counts_are_summed_over_batches(self, monkeypatch):
        calls = []

        def fake_run(command, timeout=None):
            calls.append(command)
            named = [w for w in shlex.split(command)[3:] if not w.startswith("-")]

            class Result:
                stdout = "".join(f"PASSED {n}\n" for n in named)
                stderr = ""
                returncode = 0

            return Result()

        monkeypatch.setattr(tools, "uses_django_runner", lambda: False)
        monkeypatch.setattr(score, "run", fake_run)
        monkeypatch.setattr(score, "MAX_COMMAND_CHARS", 400)
        ids = tuple(f"a/b.py::test_{i}" for i in range(300))
        outcome = score.pytest_outcome(ids, timeout=1)
        assert len(calls) > 1
        assert outcome["passed"] == 300
        assert outcome["ok"] and outcome["scoreable"]

    def test_one_failing_batch_fails_the_whole(self, monkeypatch):
        state = {"n": 0}

        def fake_run(command, timeout=None):
            state["n"] += 1

            class Result:
                stdout = "PASSED a/b.py::test_one\n" if state["n"] == 1 else "FAILED a/b.py::test_two\n"
                stderr = ""
                returncode = 0 if state["n"] == 1 else 1

            return Result()

        monkeypatch.setattr(tools, "uses_django_runner", lambda: False)
        monkeypatch.setattr(score, "run", fake_run)
        monkeypatch.setattr(score, "MAX_COMMAND_CHARS", 250)
        ids = tuple(f"a/b.py::test_{'x' * 200}_{i}" for i in range(2))
        outcome = score.pytest_outcome(ids, timeout=1)
        assert outcome["returncode"] == 1
        assert not outcome["ok"]


class TestDjangoScoring:
    """Django ships no pytest, so every Django image answered "No module named pytest".

    That is 46% of SWE-bench Verified reading as instances this environment cannot score, and
    an agent that cannot run a test on any of them.
    """

    def test_an_id_in_unittest_reporting_form_becomes_a_label(self):
        assert (
            score._django_label("test_conflicting (queries.tests.BitwiseTests)")
            == "queries.tests.BitwiseTests.test_conflicting"
        )

    def test_an_id_that_already_names_the_method_is_not_doubled(self):
        assert (
            score._django_label("test_x (aggregation.tests.Pruning.test_x)")
            == "aggregation.tests.Pruning.test_x"
        )

    def test_something_that_is_already_a_label_is_left_alone(self):
        assert score._django_label("queries.tests.Bitwise.test_x") == "queries.tests.Bitwise.test_x"

    def test_the_runner_is_used_when_the_repository_has_one(self, monkeypatch):
        seen = {}

        def fake_run(command, timeout=None):
            seen["command"] = command

            class Result:
                stdout = "test_x (m.C.test_x) ... ok\n"
                stderr = ""
                returncode = 0

            return Result()

        monkeypatch.setattr(tools, "uses_django_runner", lambda: True)
        monkeypatch.setattr(score, "run", fake_run)
        outcome = score.pytest_outcome(("test_x (m.C)",), timeout=1)
        assert "runtests.py" in seen["command"]
        assert "m.C.test_x" in seen["command"]
        assert outcome["basis"] == "django per-test lines"
        assert outcome["ok"]

    def test_a_docstring_does_not_hide_the_result(self):
        """unittest puts the docstring where the name would be, so the result is matched at the
        end of the line rather than the start."""
        text = (
            "test_x (m.C.test_x)\nDoes the thing ... ok\n"
            "test_y (m.C.test_y)\nDoes another ... FAIL\n"
        )
        counts = score._django_counts(text)
        assert (counts["passed"], counts["failed"]) == (1, 1)

    def test_a_label_the_runner_cannot_import_is_not_a_failing_test(self):
        text = "NoSuch (unittest.loader._FailedTest.NoSuch) ... ERROR\n"
        assert score._django_counts(text)["load_error"] is True

    def test_that_makes_the_instance_unscoreable(self, monkeypatch):
        class Result:
            stdout = "NoSuch (unittest.loader._FailedTest.NoSuch) ... ERROR\n"
            stderr = ""
            returncode = 1

        monkeypatch.setattr(tools, "uses_django_runner", lambda: True)
        monkeypatch.setattr(score, "run", lambda command, timeout=None: Result())
        outcome = score.pytest_outcome(("test_x (m.C)",), timeout=1)
        assert outcome["scoreable"] is False
        assert "could not load" in outcome["basis"]


class TestAgentTestCommand:
    def test_pytest_by_default(self, monkeypatch):
        monkeypatch.setattr(tools, "uses_django_runner", lambda: False)
        assert tools.test_command("tests/test_x.py") == "python -m pytest tests/test_x.py -x -q"

    def test_django_gets_a_dotted_label(self, monkeypatch):
        monkeypatch.setattr(tools, "uses_django_runner", lambda: True)
        command = tools.test_command("tests/queries/tests.py")
        assert command.endswith("queries.tests")
        assert "runtests.py" in command

    def test_a_pytest_style_node_id_is_translated(self, monkeypatch):
        monkeypatch.setattr(tools, "uses_django_runner", lambda: True)
        assert tools.test_command("tests/queries/tests.py::Bitwise::test_x").endswith(
            "queries.tests.Bitwise.test_x"
        )

    def test_a_label_the_model_already_got_right_is_untouched(self, monkeypatch):
        monkeypatch.setattr(tools, "uses_django_runner", lambda: True)
        assert tools.test_command("queries.tests").endswith("queries.tests")


class TestRepairingTheDatasetsOwnIds:
    """`PASS_TO_PASS` is stored whitespace-separated, so a parametrised case with a space in it
    arrives as fragments. Eleven of the twenty-four instances in the pilot subset have some, and
    every fragment is a test pytest cannot find — which took the run to exit 4 and the instance
    out of the comparison entirely.
    """

    def test_fragments_are_rejoined_on_bracket_balance(self):
        assert score.repair_ids(
            ("a.py::test_powers[-10-1", "/", "10]", "a.py::test_x[1.0-m]")
        ) == ("a.py::test_powers[-10-1 / 10]", "a.py::test_x[1.0-m]")

    def test_a_balanced_list_is_untouched(self):
        ids = ("a.py::test_x", "a.py::test_y[1-2]")
        assert score.repair_ids(ids) == ids

    def test_a_fragment_that_never_closes_is_left_for_the_runner_to_reject(self):
        assert score.repair_ids(("a.py::test_x[oops",)) == ("a.py::test_x[oops",)

    def test_ids_pytest_reports_missing_are_read_back(self):
        text = (
            "ERROR: not found: /testbed/a.py::test_z[q\n"
            "(no name '/testbed/a.py::test_z[q' in any of [<Module a.py>])\n"
        )
        assert score._not_found(text) == {"a.py::test_z[q"}

    def outcome(self, monkeypatch, *, decisive, missing_first_run):
        """Two runs: the first reports the missing ids, the second is clean."""
        state = {"n": 0, "commands": []}

        def fake_run(command, timeout=None):
            state["n"] += 1
            state["commands"].append(command)
            named = [w for w in shlex.split(command)[3:] if not w.startswith("-")]
            first = state["n"] == 1

            class Result:
                stdout = (
                    "".join(f"ERROR: not found: /testbed/{m}\n" for m in missing_first_run)
                    if first
                    else "".join(f"PASSED {n}\n" for n in named)
                )
                stderr = ""
                returncode = 4 if first else 0

            return Result()

        monkeypatch.setattr(tools, "uses_django_runner", lambda: False)
        monkeypatch.setattr(score, "run", fake_run)
        ids = tuple(f"a/b.py::test_{i}" for i in range(20))
        return score.pytest_outcome(ids, timeout=1, decisive=decisive), state

    def test_a_regression_list_drops_the_missing_ids_and_says_which(self, monkeypatch):
        result, state = self.outcome(
            monkeypatch, decisive=False, missing_first_run=["a/b.py::test_3"]
        )
        assert result["scoreable"] and result["ok"]
        assert result["not_in_checkout"] == ["a/b.py::test_3"]
        assert state["n"] == 2
        assert "test_3 " not in state["commands"][1] + " "

    def test_the_decisive_list_is_not_scored_on_a_subset(self, monkeypatch):
        """Scoring "did you fix it" on some of the tests that define the fix is a different
        question wearing the same name."""
        result, state = self.outcome(
            monkeypatch, decisive=True, missing_first_run=["a/b.py::test_3"]
        )
        assert result["scoreable"] is False
        assert result["basis"] == "ids this checkout does not contain"
        assert state["n"] == 1

    def test_losing_most_of_the_regression_list_is_not_a_score_either(self, monkeypatch):
        result, _ = self.outcome(
            monkeypatch,
            decisive=False,
            missing_first_run=[f"a/b.py::test_{i}" for i in range(15)],
        )
        assert result["scoreable"] is False


class TestWhoBrokeTheSuite:
    """A patch that stops the suite from running is a failed attempt, not an exclusion.

    Recorded as unscoreable, it leaves the comparison — which excuses exactly the arms whose
    patches do not parse. One self-hosted episode replaced a method definition in Django's
    query.py with an unclosed heredoc marker; every test then failed to import, and the episode
    was on course to be dropped rather than failed.
    """

    def test_the_patch_is_blamed_when_the_clean_checkout_runs(self):
        broken = {"scoreable": False, "basis": "exit status only, no per-test lines"}
        clean = {"scoreable": True, "basis": "per-test lines"}
        assert score.blames_the_patch(broken, clean)

    def test_the_environment_is_blamed_when_the_clean_checkout_fails_too(self):
        broken = {"scoreable": False, "basis": "exit status only, no per-test lines"}
        clean = {"scoreable": False, "basis": "exit status only, no per-test lines"}
        assert not score.blames_the_patch(broken, clean)

    def test_a_dataset_problem_is_never_the_patch(self):
        """Ids the checkout does not contain are missing whatever the agent did."""
        broken = {"scoreable": False, "basis": "ids this checkout does not contain"}
        clean = {"scoreable": True, "basis": "per-test lines"}
        assert not score.blames_the_patch(broken, clean)

    def test_a_scoreable_run_is_not_reinterpreted(self):
        assert not score.blames_the_patch(
            {"scoreable": True, "basis": "per-test lines"},
            {"scoreable": True, "basis": "per-test lines"},
        )


class TestUnclosedPatchBlocks:
    def test_an_unclosed_block_is_refused_rather_than_applied(self):
        """`new: <<<` with no terminator leaves the marker as the value, and applying it writes
        `<<<` into the repository."""
        observation = tools._write_patch({"path": "a.py", "old": "x", "new": "<<<"})
        assert not observation.ok
        assert "never closed" in observation.text

    def test_the_same_for_the_old_side(self):
        observation = tools._write_patch({"path": "a.py", "old": "<<<", "new": "y"})
        assert not observation.ok

    def test_a_patch_that_merely_mentions_the_marker_is_fine(self, monkeypatch):
        """Refusing any patch containing `<<<` would refuse a fix to a conflict-marker parser."""
        seen = {}
        monkeypatch.setattr(
            tools, "_edit", lambda path, old, new: seen.setdefault("called", True), raising=False
        )
        observation = tools._write_patch(
            {"path": "a.py", "old": "if x:\n    pass", "new": "if x:  # <<< see below\n    pass"}
        )
        assert "never closed" not in observation.text


class TestDjangosPollutedList:
    def test_a_docstring_line_is_not_a_test_name(self):
        """unittest prints the docstring under the name, and SWE-bench's parser kept some of
        those lines as if they were tests: 14 of django-17084's 107 are English sentences."""
        labels, rest = score._django_ids(
            (
                "test_x (aggregation.tests.Pruning.test_x)",
                "Random() is not included in the GROUP BY when used for ordering.",
                "test_y (aggregation.tests.Pruning)",
            )
        )
        assert labels == (
            "aggregation.tests.Pruning.test_x",
            "aggregation.tests.Pruning.test_y",
        )
        assert rest == ("Random() is not included in the GROUP BY when used for ordering.",)

    def test_a_list_that_is_mostly_prose_is_not_evidence(self, monkeypatch):
        monkeypatch.setattr(tools, "uses_django_runner", lambda: True)
        outcome = score.pytest_outcome(
            ("A sentence.", "Another sentence.", "test_x (m.C)"), timeout=1
        )
        assert outcome["scoreable"] is False
        assert "not test names" in outcome["basis"]


class TestFragmentsWithNoTail:
    def test_two_truncated_ids_are_not_welded_together(self):
        """matplotlib keeps the head of each parametrised id and drops the tail, so bracket
        balance alone would join `[args0-Length` to `[args1-Length` and lose both."""
        ids = (
            "t.py::test_shape_error[args0-Length",
            "t.py::test_shape_error[args1-Length",
            "t.py::test_other",
        )
        assert score.repair_ids(ids) == ids

    def test_a_real_continuation_is_still_joined(self):
        ids = ("t.py::test_powers[-10-1", "/", "10]", "t.py::test_x")
        assert score.repair_ids(ids) == ("t.py::test_powers[-10-1 / 10]", "t.py::test_x")


# --- grammar v2: the tolerant argument encodings, and what they must refuse ------------------
#
# Frozen with the reader. The rules exist because a self-hosted Qwen3.6-35B-A3B wrote 68.8% of its
# arguments in its own tool-calling dialect inside the harness's block and scored zero for it while
# naming the right tool every time. The tests that matter most here are the refusals: a reader that
# also rescued invented tools or empty arguments would be absorbing the model's real failures.


def test_canonical_form_is_unchanged_and_not_marked_tolerant():
    action = tools.parse_all('<action tool="search">\npattern: def prepare_body\n</action>')[0]
    assert action.args == {"pattern": "def prepare_body"}
    assert action.encodings == ("canonical",)
    assert action.tolerant is False


def test_parameter_tag_is_read_as_the_same_argument():
    action = tools.parse_all(
        '<action tool="search">\n<parameter=pattern>\nqdp\n</parameter>\n</action>'
    )[0]
    assert action.args == {"pattern": "qdp"}
    assert action.tolerant is True


def test_element_tag_is_read_for_a_name_the_tool_owns():
    action = tools.parse_all('<action tool="list_dir">\n<dir>\n/testbed\n</dir>\n</action>')[0]
    assert action.args == {"dir": "/testbed"}
    assert action.tolerant is True


def test_element_tag_is_ignored_for_a_name_the_tool_does_not_own():
    # Otherwise a model thinking out loud acquires an argument called "thinking".
    action = tools.parse_all(
        '<action tool="search">\n<thinking>\nlet me look\n</thinking>\npattern: qdp\n</action>'
    )[0]
    assert action.args == {"pattern": "qdp"}
    assert action.tolerant is False


def test_an_empty_value_is_not_rescued():
    action = tools.parse_all('<action tool="search">\npattern:\n</action>')[0]
    assert action.args == {"pattern": ""}
    assert action.tolerant is False
    assert tools.execute(action).ok is False


def test_an_empty_line_does_not_block_the_value_the_model_then_gave():
    # The skeleton followed by the value in the model's own dialect is one intent, not a conflict.
    action = tools.parse_all(
        '<action tool="search">\npattern:\n<parameter=pattern>\nqdp\n</parameter>\n</action>'
    )[0]
    assert action.args == {"pattern": "qdp"}
    assert action.tolerant is True


def test_a_colon_inside_a_tag_body_is_not_a_second_argument():
    action = tools.parse_all(
        '<action tool="search">\n<parameter=pattern>\nfoo: bar\n</parameter>\n</action>'
    )[0]
    assert action.args == {"pattern": "foo: bar"}


def test_an_invented_tool_gains_no_arguments_and_is_still_refused():
    action = tools.parse_all(
        '<action tool="run_command">\n<parameter=command>\nls\n</parameter>\n</action>'
    )[0]
    assert action.args == {}
    observation = tools.execute(action)
    assert observation.ok is False
    assert "no tool called" in observation.text


def test_the_first_non_empty_value_wins_and_nothing_is_synthesised():
    action = tools.parse_all(
        '<action tool="search">\npattern: canonical\n<parameter=pattern>\ndialect\n</parameter>\n</action>'
    )[0]
    assert action.args == {"pattern": "canonical"}
    assert action.tolerant is False


def test_heredoc_arguments_still_win_over_everything():
    action = tools.parse_all(
        '<action tool="write_patch">\npath: a.py\n'
        "old: <<<\n  if x: pass\n>>>\nnew: <<<\n  if x:\n    pass\n>>>\n</action>"
    )[0]
    assert action.args["old"] == "  if x: pass"
    assert action.args["new"] == "  if x:\n    pass"
    assert action.tolerant is False


def test_a_missing_argument_error_shows_the_form_that_would_work():
    # The v1 error said only "search needs a pattern", and the model answered it by switching
    # further into its own dialect. An error that restates the grammar is environment quality.
    observation = tools.execute(tools.Action(tool="search", args={}))
    assert observation.ok is False
    assert '<action tool="search">' in observation.text
    assert "pattern: " in observation.text


# --- the Responses wire ---------------------------------------------------------------------
#
# A second wire exists because this gateway refuses function tools together with any
# reasoning_effort other than "none" on chat completions, and a comparator with its reasoning
# switched off is a different model. The translation is the whole surface, so it is pinned here.


def test_responses_body_turns_chat_history_into_items():
    import transport
    messages = [
        {"role": "system", "content": "sys"},
        {"role": "user", "content": "task"},
        {"role": "assistant", "content": None, "tool_calls": [
            {"id": "c1", "type": "function",
             "function": {"name": "search", "arguments": '{"pattern":"x"}'}}]},
        {"role": "tool", "tool_call_id": "c1", "content": "no match"},
    ]
    body = transport._responses_body("m", messages, 800, "high", tools.schemas())
    kinds = [item.get("type") or item.get("role") for item in body["input"]]
    assert kinds == ["system", "user", "function_call", "function_call_output"]
    assert body["input"][2]["call_id"] == body["input"][3]["call_id"] == "c1"
    assert body["reasoning"] == {"effort": "high"}
    assert "max_output_tokens" in body and "max_tokens" not in body


def test_responses_declares_tools_flat_not_nested():
    import transport
    body = transport._responses_body("m", [{"role": "user", "content": "x"}], 10, None, tools.schemas())
    first = body["tools"][0]
    assert first["type"] == "function" and "function" not in first
    assert first["name"] and first["parameters"]


def test_responses_stream_folds_a_call_and_reads_the_other_usage_spelling():
    import transport
    reply = transport.Reply(model="m")
    for event in (
        {"type": "response.output_item.added",
         "item": {"type": "function_call", "call_id": "c9", "name": "search", "arguments": ""}},
        {"type": "response.function_call_arguments.delta", "delta": '{"pattern":'},
        {"type": "response.function_call_arguments.delta", "delta": '"qdp"}'},
        {"type": "response.completed", "response": {"status": "completed", "usage": {
            "input_tokens": 300, "output_tokens": 40,
            "input_tokens_details": {"cached_tokens": 200},
            "output_tokens_details": {"reasoning_tokens": 30}}}},
    ):
        transport._responses_event(reply, event, 0.0, [])
    assert tools.from_tool_calls(reply.tool_calls)[0].args == {"pattern": "qdp"}
    assert reply.finish_reason == "stop"
    assert (reply.prompt_tokens, reply.completion_tokens) == (300, 40)
    assert (reply.cached_prompt_tokens, reply.reasoning_tokens) == (200, 30)


def test_a_responses_turn_cut_off_at_the_limit_is_reported_as_length():
    # Otherwise the loop files it as the model failing to follow a format, and the capacity policy
    # withdraws a tier on that count.
    import transport
    reply = transport.Reply(model="m")
    transport._responses_event(reply, {"type": "response.incomplete", "response": {
        "status": "incomplete", "incomplete_details": {"reason": "max_output_tokens"}}}, 0.0, [])
    assert reply.finish_reason == "length"


def test_responses_visible_text_survives_the_end_of_the_stream():
    # The chat path assigns reply.text from a local accumulator when the stream closes, so the
    # Responses path has to append to the same list. Writing to reply.text directly was silently
    # undone, and every verdict in a judge pass came back unparseable with no error to show for it.
    import transport
    reply = transport.Reply(model="m")
    parts: list[str] = []
    for event in (
        {"type": "response.output_text.delta", "delta": "VERDICT: "},
        {"type": "response.output_text.delta", "delta": "FIXED"},
        {"type": "response.completed", "response": {"status": "completed"}},
    ):
        transport._responses_event(reply, event, 0.0, parts)
    assert "".join(parts) == "VERDICT: FIXED"
