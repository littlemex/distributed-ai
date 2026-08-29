#!/usr/bin/env python3
"""Decide whether an episode succeeded, inside the official evaluation image.

    python score.py --instance /work/instance.json --out /work/score.json

Run after the agent has finished and its diff has been captured. The order matters and is
the whole contract:

1. The agent works on `/testbed` and never sees the tests that judge it. The test patch is
   applied *here*, after its diff is taken, because an agent that can read the test knows
   the answer and the episode stops measuring anything.
2. An agent that edits a test file has changed its own examiner. That is detected and the
   episode is failed rather than silently scored, because it is the single most likely way
   for a run to produce a number that flatters the model.
3. `FAIL_TO_PASS` must pass and `PASS_TO_PASS` must still pass. The second half is what
   separates a fix from a change that breaks the rest of the library, and it is most of the
   test time.

4. The checkout is reset before anything is applied. The agent edited `/testbed` in place,
   so re-applying its own diff on top of its own edits fails — and a *correct* fix fails
   most reliably, because it is the one that applied cleanly the first time. Scoring in the
   same container as the episode is the normal case, so the reset is done here rather than
   assumed of whoever runs it.

The scorer never sees the gold patch. It exists in the instance data for the smoke test
that proves this environment can distinguish a fix from no fix at all.
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tools  # noqa: E402  (shipped alongside; see below)

# Taken from `tools`, not copied. The two must agree about what counts as touching the
# examination: if the agent is allowed an edit the scorer voids the episode for, the run
# produces failures that are the harness disagreeing with itself.
TESTBED = tools.TESTBED
CONDA_ACTIVATE = tools.CONDA
# One test file's failures should not hide another's, and a repository's suite can be long.
DEFAULT_TIMEOUT = 1800
# Colour codes, which arrive whether or not there is a terminal: several of these repositories
# force colour from their own configuration. Left in, `^PASSED ` never matches — astropy's
# suite reported 179 of 179 tests passing and the instance was recorded as impossible to score
# here, which excludes exactly the repositories with the most opinionated test setup.
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# One argument to `execve` is capped at 128 KiB on Linux, and the whole `bash -lc` script is
# one argument. xarray names 785 tests to keep passing; quoted, that is 137 KiB, and the
# scorer raised "argument list too long" after the episode had already run.
MAX_COMMAND_CHARS = 60_000
# How much of a regression list may be missing from the checkout before the instance stops
# being evidence. Not zero, because the dataset's own lists are damaged in ways nothing here
# can repair: matplotlib keeps only the first word of a parametrised id and drops the rest, and
# Django's list contains docstring lines its log parser mistook for test names. A tenth was too
# strict to keep instances that are otherwise perfectly runnable; a quarter still leaves three
# quarters of the regression suite guarding the fix, and what was dropped is named in the
# verdict either way.
MAX_DROPPED_SHARE = 0.25


def run(command: str, *, timeout: int = DEFAULT_TIMEOUT) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["/bin/bash", "-lc", f"cd {TESTBED} && {CONDA_ACTIVATE} && {command}"],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def touched_tests(diff: str) -> list[str]:
    """Files in the agent's diff that are part of the examination.

    Test files, and also anything that decides whether the suite runs or what it reports —
    a `conftest.py` that skips everything makes pytest exit zero, which would otherwise
    read as a fix.
    """
    paths = re.findall(r"^\+\+\+ b/(.+)$", diff, flags=re.MULTILINE)
    return [path for path in paths if tools.is_test_path(path)]


def reset_checkout() -> None:
    """Undo the agent's edits before anything is applied.

    Tracked files only, and deliberately no `git clean`: several of these images ship an
    untracked `build/` tree that belongs to the environment, and deleting it would change
    what the suite runs against. The tool set cannot create files, so restoring tracked
    ones restores the checkout.
    """
    run("git checkout -- .")


def pytest_outcome(tests: tuple[str, ...], *, timeout: int, decisive: bool = False) -> dict:
    """Run named tests and report what happened, without reading silence as success.

    A zero exit status is not enough on its own. pytest exits zero when every test was
    skipped, and it exits zero when a `conftest.py` arranged for that, so the verdict here
    is that every named test reported PASSED. `-rA` lists one line per test, and the count
    is taken from the whole output rather than a truncated tail — an earlier version
    counted within the last four thousand characters and then papered over the undercount
    by trusting the exit status, which is the assumption being removed.

    Long id lists are run in batches. Linux caps a single argument at 128 KiB, and xarray
    names 785 `PASS_TO_PASS` tests: one command was 137 KiB and `subprocess` raised
    "argument list too long" *after* the episode had run, so a finished attempt had no verdict
    at all. The batches are aggregated below rather than the first one being reported.
    """
    if not tests:
        return {"ran": 0, "passed": 0, "failed": 0, "ok": False, "scoreable": False,
                "detail": "no tests named: this instance cannot be scored"}
    django = tools.uses_django_runner()
    not_ids: tuple[str, ...] = ()
    if django:
        tests, not_ids = _django_ids(tests)
        if not tests or len(not_ids) > MAX_DROPPED_SHARE * (len(tests) + len(not_ids)):
            return {"ran": len(tests) + len(not_ids), "passed": 0, "failed": 0, "skipped": 0,
                    "ok": False, "scoreable": False, "returncode": None,
                    "basis": "the dataset's list is mostly not test names",
                    "not_in_checkout": sorted(not_ids)[:20], "detail": ""}
    else:
        tests = repair_ids(tests)
    batches = _batched(tests)
    results = []
    for batch in batches:
        try:
            results.append(_run_batch(batch, django=django, timeout=timeout))
        except subprocess.TimeoutExpired:
            # Recorded rather than raised. An uncaught timeout writes no score.json, and the
            # instances whose suites are slowest are the hard ones — so the arm that attempts
            # them would silently lose them from its denominator.
            return {"ran": len(tests), "passed": 0, "failed": 0, "skipped": 0, "ok": False,
                    "scoreable": False, "returncode": None, "basis": "timeout",
                    "detail": f"a batch did not finish within {timeout}s"}

    missing = set().union(*(_not_found(r["text"]) for r in results)) if results else set()
    dropped: tuple[str, ...] = ()
    if missing and not django:
        remaining = tuple(test for test in tests if test not in missing)
        # The decisive list has to be complete: scoring "did you fix it" on a subset of the
        # tests that define the fix is a different question with the same name. A regression
        # list may lose a few and say so — but not most of itself.
        if not decisive and remaining and len(remaining) >= (1 - MAX_DROPPED_SHARE) * len(tests):
            dropped = tuple(sorted(missing))
            results = [_run_batch(b, django=django, timeout=timeout) for b in _batched(remaining)]
            tests = remaining
        else:
            return {"ran": len(tests), "passed": 0, "failed": 0, "skipped": 0, "ok": False,
                    "scoreable": False, "returncode": 4,
                    "basis": "ids this checkout does not contain",
                    "not_in_checkout": sorted({*missing, *not_ids})[:20],
                    "detail": "\n".join(r["text"][-600:] for r in results)[-1600:]}

    passed = sum(r["passed"] for r in results)
    failed = sum(r["failed"] for r in results)
    skipped = sum(r["skipped"] for r in results)
    codes = [r["returncode"] for r in results]
    returncode = next((c for c in codes if c != 0), 0)
    detail = "\n".join(r["text"][-1200 // len(results):] for r in results)

    basis, scoreable = ("django per-test lines" if django else "per-test lines"), True
    if any(r["load_error"] for r in results):
        # A label the runner could not import. That says nothing about the code, and counting
        # it as a failure would put "could not be scored" into the denominator as "did not
        # solve it".
        basis, scoreable = "the runner could not load a named test", False
    elif returncode == 4 and not django:
        # pytest could not make sense of the target. `tools._verdict` reads the same status the
        # same way, so the loop and the scorer agree.
        basis, scoreable = "pytest rejected the target (exit 4)", False
    elif passed == 0 and failed == 0 and skipped == 0:
        # No per-test lines at all. The exit status is the only evidence left, and it is
        # weaker than the rule above it — pytest exits zero when everything was skipped — so
        # the episode is marked unscoreable and excluded rather than counted on trust.
        basis, scoreable = "exit status only, no per-test lines", False
        passed = len(tests) if returncode == 0 else 0
    return {
        "ran": len(tests),
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "batches": len(results),
        # Named, not just counted: a reader has to be able to check that what was dropped was
        # a fragment of the dataset's own list and not a test the episode broke.
        "not_in_checkout": sorted({*dropped, *not_ids}),
        "ok": returncode == 0 and passed >= len(tests),
        "scoreable": scoreable,
        "returncode": returncode,
        "basis": basis,
        "detail": detail[-1600:],
    }


def repair_ids(tests: tuple[str, ...]) -> tuple[str, ...]:
    """Re-join ids that the dataset split on whitespace.

    `PASS_TO_PASS` is stored whitespace-separated, so a parametrised id whose case contains a
    space arrives as fragments: `test_powers[-10-1`, `/`, `10]`. Eleven of the twenty-four
    instances in the pilot subset have some — up to 36 of matplotlib's 813 — and every fragment
    is a test pytest cannot find, which took the whole run to exit 4 and the whole instance out
    of the comparison.

    Bracket balance is the join rule: a fragment is an id with an unmatched `[`, and the
    following entries belong to it until the brackets close. Single spaces, because that is
    what splitting on whitespace leaves. An id this cannot repair is reported by pytest as not
    found, and handled there rather than guessed at here.
    """
    out: list[str] = []
    pending: list[str] = []
    for test in tests:
        # Only a continuation is absorbed, and a continuation never names a module: matplotlib's
        # list keeps the head of each truncated id and drops the tail entirely, so joining on
        # bracket balance alone would weld `[args0-Length` to `[args1-Length` and lose both.
        if pending and "::" in test:
            out.extend(pending)
            pending = []
        pending.append(test)
        joined = " ".join(pending)
        if joined.count("[") <= joined.count("]"):
            out.append(joined)
            pending = []
    if pending:
        # Never balanced. Kept as it stands so the runner is the one to say it does not exist.
        out.extend(pending)
    return tuple(out)


def _not_found(text: str) -> set[str]:
    """The ids pytest says this checkout does not contain, as we asked for them."""
    found = set()
    for line in re.findall(r"^ERROR: not found: (.+)$", text, flags=re.MULTILINE):
        name = line.strip()
        prefix = f"{str(TESTBED).rstrip('/')}/"
        found.add(name[len(prefix):] if name.startswith(prefix) else name)
    return found


def _batched(tests: tuple[str, ...], *, budget: int | None = None) -> list[tuple[str, ...]]:
    """Split ids into commands short enough to hand to a shell.

    The limit is per argument, not per command line: the whole `bash -lc` script is one
    argument, and Linux caps it at 128 KiB whatever `ARG_MAX` says.
    """
    budget = budget or MAX_COMMAND_CHARS
    out: list[tuple[str, ...]] = []
    current: list[str] = []
    length = 0
    for test in tests:
        cost = len(shlex.quote(test)) + 1
        if current and length + cost > budget:
            out.append(tuple(current))
            current, length = [], 0
        current.append(test)
        length += cost
    if current:
        out.append(tuple(current))
    return out


def _run_batch(tests: tuple[str, ...], *, django: bool, timeout: int) -> dict:
    """One invocation of whichever runner this repository uses, and what it reported."""
    quoted = " ".join(shlex.quote(test) for test in tests)
    command = (
        f"{tools.DJANGO_COMMAND} {quoted}"
        if django
        else f"python -m pytest {quoted} -rA -q --color=no"
    )
    result = run(command, timeout=timeout)
    # `--color=no` asks, and stripping the codes makes sure: a plugin or a repository's own
    # `addopts` can put them back, and the per-test count is the whole verdict.
    whole = ANSI.sub("", result.stdout + result.stderr)
    counts = _django_counts(whole) if django else _pytest_counts(whole)
    return {**counts, "returncode": result.returncode, "text": whole}


def _pytest_counts(whole: str) -> dict:
    return {
        "passed": len(re.findall(r"^PASSED ", whole, flags=re.MULTILINE)),
        "failed": len(re.findall(r"^(FAILED|ERROR) ", whole, flags=re.MULTILINE)),
        "skipped": len(re.findall(r"^(SKIPPED|XFAIL) ", whole, flags=re.MULTILINE)),
        "load_error": False,
    }


def _django_counts(whole: str) -> dict:
    """Count unittest's verbosity-2 lines.

    Matched at the end of the line rather than the start, because a test with a docstring puts
    the docstring where the name would be: `test_x (mod.Class)` then `Does the thing ... ok`.
    """
    return {
        "passed": len(re.findall(r"\.\.\. ok$", whole, flags=re.MULTILINE)),
        "failed": len(re.findall(r"\.\.\. (FAIL|ERROR)$", whole, flags=re.MULTILINE)),
        "skipped": len(re.findall(r"\.\.\. (skipped|expected failure)", whole)),
        # The runner reports a label it could not import as a test that errored, which would
        # otherwise be indistinguishable from the code being broken.
        "load_error": "unittest.loader._FailedTest" in whole,
    }


def _django_ids(tests: tuple[str, ...]) -> tuple[tuple[str, ...], tuple[str, ...]]:
    """Split the dataset's Django list into labels the runner can take, and the rest.

    unittest prints a test's docstring on the line after its name, and SWE-bench's log parser
    kept some of those lines as if they were test names: 14 of django-17084's 107
    `PASS_TO_PASS` entries are English sentences. Handing one to the runner raises "Empty module
    name" and takes the whole instance out of the comparison, so they are separated here and
    named in the verdict.
    """
    labels: list[str] = []
    rest: list[str] = []
    for test in tests:
        label = _django_label(test)
        looks_like_a_label = bool(re.fullmatch(r"[\w.]+", label)) and "." in label
        (labels if looks_like_a_label else rest).append(label if looks_like_a_label else test)
    return tuple(labels), tuple(rest)


def _django_label(test_id: str) -> str:
    """`test_x (mod.Class)` or `test_x (mod.Class.test_x)` as a label the runner accepts.

    SWE-bench records Django's ids in unittest's own reporting format, which is not the form
    the runner takes on its command line.
    """
    match = re.match(r"^(\S+)\s+\((.+)\)$", test_id.strip())
    if not match:
        return test_id.strip()
    name, dotted = match.group(1), match.group(2)
    return dotted if dotted.split(".")[-1] == name else f"{dotted}.{name}"


# The bases that can be the patch's fault. A run that produced no per-test lines either could
# not import the code or was stopped before collection, and a patch is quite capable of causing
# both. The other bases are properties of the dataset or of the image and cannot be.
BLAMEABLE = ("exit status only, no per-test lines",)


def blames_the_patch(outcome: dict, baseline: dict) -> bool:
    """Whether the patch, rather than this environment, is why nothing ran.

    Without this the two are the same verdict: an episode whose patch broke the module produced
    no per-test lines, was recorded unscoreable, and left the comparison — which excuses exactly
    the arms whose patches do not parse, and those are the cheap ones. The baseline run is the
    same suite with the agent's diff reverted and only the test patch applied.
    """
    return (
        not outcome.get("scoreable")
        and outcome.get("basis") in BLAMEABLE
        and bool(baseline.get("scoreable"))
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--instance", type=Path, required=True)
    parser.add_argument("--diff", type=Path, default=None, help="the agent's patch")
    parser.add_argument(
        "--apply-gold",
        action="store_true",
        help="score the reference fix instead of an agent's, to prove the environment can "
        "tell the difference",
    )
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)

    instance = json.loads(args.instance.read_text())
    verdict: dict[str, object] = {"instance_id": instance["instance_id"]}

    diff = args.diff.read_text() if args.diff and args.diff.exists() else ""
    verdict["diff_bytes"] = len(diff)
    # Before anything is applied: the episode ran in this checkout and left its edits here.
    reset_checkout()
    if args.apply_gold:
        diff = instance["gold_patch"]
        verdict["scored"] = "gold_patch"
    else:
        verdict["scored"] = "agent_patch"
        cheated = touched_tests(diff)
        if cheated:
            verdict.update(
                resolved=False,
                reason="the patch edits test files",
                touched_tests=cheated,
            )
            args.out.write_text(json.dumps(verdict, indent=2))
            print(f"[FAIL] the patch edits {cheated}; failing the episode")
            return 0

    if diff.strip():
        applied = subprocess.run(
            ["/bin/bash", "-lc", f"cd {TESTBED} && git apply -v -"],
            input=diff,
            capture_output=True,
            text=True,
        )
        verdict["patch_applied"] = applied.returncode == 0
        if applied.returncode != 0:
            verdict.update(resolved=False, reason="the patch does not apply",
                           detail=(applied.stderr or "")[-800:])
            args.out.write_text(json.dumps(verdict, indent=2))
            print("[FAIL] patch did not apply")
            return 0
    else:
        verdict["patch_applied"] = False

    # Applied last, so nothing the agent did could have read it.
    test_patch = subprocess.run(
        ["/bin/bash", "-lc", f"cd {TESTBED} && git apply -v -"],
        input=instance["test_patch"],
        capture_output=True,
        text=True,
    )
    verdict["test_patch_applied"] = test_patch.returncode == 0
    if test_patch.returncode != 0:
        verdict.update(resolved=False, reason="the test patch does not apply",
                       detail=(test_patch.stderr or "")[-800:])
        args.out.write_text(json.dumps(verdict, indent=2))
        print("[FAIL] test patch did not apply — the episode cannot be scored")
        return 1

    fail_to_pass = pytest_outcome(
        tuple(instance["fail_to_pass"]), timeout=args.timeout, decisive=True
    )
    pass_to_pass = pytest_outcome(tuple(instance["pass_to_pass"]), timeout=args.timeout)
    scoreable = fail_to_pass.get("scoreable", True) and pass_to_pass.get("scoreable", True)

    # A patch that stops the suite from running at all is a failure, not an exclusion. Asked
    # only when something did not run and the agent had changed something, because it costs a
    # second run of the decisive tests.
    if not scoreable and verdict.get("patch_applied") and not args.apply_gold:
        reset_checkout()
        subprocess.run(
            ["/bin/bash", "-lc", f"cd {TESTBED} && git apply -v -"],
            input=instance["test_patch"], capture_output=True, text=True,
        )
        baseline = pytest_outcome(
            tuple(instance["fail_to_pass"]), timeout=args.timeout, decisive=True
        )
        if blames_the_patch(fail_to_pass, baseline) or blames_the_patch(pass_to_pass, baseline):
            scoreable = True
            verdict["broke_the_suite"] = True
            verdict["reason"] = (
                "the patch stopped the suite from running; the same tests run on this checkout "
                "with the patch reverted, so this is a failed attempt and not an instance the "
                "environment cannot score"
            )
        else:
            verdict["baseline_basis"] = baseline.get("basis")
    verdict.update(
        fail_to_pass=fail_to_pass,
        pass_to_pass=pass_to_pass,
        resolved=bool(fail_to_pass["ok"] and pass_to_pass["ok"]),
        # Whether this episode belongs in the comparison at all. An instance whose suite
        # this environment cannot run is not evidence that a policy failed to fix it, and
        # the instances that break hardest are the hard ones — so counting them as failures
        # would bias against whichever arm reached them.
        scoreable=scoreable,
    )
    if not scoreable and "reason" not in verdict:
        verdict["reason"] = (
            "this instance could not be scored here: "
            f"fail_to_pass={fail_to_pass.get('basis')}, pass_to_pass={pass_to_pass.get('basis')}"
        )
    args.out.write_text(json.dumps(verdict, indent=2))
    print(
        f"[{'OK' if verdict['resolved'] else 'UNSCOREABLE' if not scoreable else 'FAIL'}] "
        f"{instance['instance_id']}: "
        f"fail_to_pass={'pass' if fail_to_pass['ok'] else 'fail'} "
        f"pass_to_pass={'pass' if pass_to_pass['ok'] else 'fail'}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
