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


def pytest_outcome(tests: tuple[str, ...], *, timeout: int) -> dict:
    """Run named tests and report what happened, without reading silence as success.

    A zero exit status is not enough on its own. pytest exits zero when every test was
    skipped, and it exits zero when a `conftest.py` arranged for that, so the verdict here
    is that every named test reported PASSED. `-rA` lists one line per test, and the count
    is taken from the whole output rather than a truncated tail — an earlier version
    counted within the last four thousand characters and then papered over the undercount
    by trusting the exit status, which is the assumption being removed.
    """
    if not tests:
        return {"ran": 0, "passed": 0, "failed": 0, "ok": False, "scoreable": False,
                "detail": "no tests named: this instance cannot be scored"}
    # `shlex.quote`, not double quotes around each id. A parametrised id can contain spaces,
    # quotes and backslashes — astropy's unit tests are named after the unit strings they
    # parse — and hand-quoting split 732 ids into fragments pytest could not find, which came
    # back as exit 4 and read as "this instance cannot be scored here".
    quoted = " ".join(shlex.quote(test) for test in tests)
    try:
        result = run(f"python -m pytest {quoted} -rA -q --color=no", timeout=timeout)
    except subprocess.TimeoutExpired:
        # Recorded rather than raised. An uncaught timeout writes no score.json, and the
        # instances whose suites are slowest are the hard ones — so the arm that attempts
        # them would silently lose them from its denominator.
        return {"ran": len(tests), "passed": 0, "failed": 0, "skipped": 0, "ok": False,
                "scoreable": False, "returncode": None, "basis": "timeout",
                "detail": f"the suite did not finish within {timeout}s"}
    # `--color=no` asks, and stripping the codes makes sure: a plugin or a repository's own
    # `addopts` can put them back, and the per-test count is the whole verdict.
    whole = ANSI.sub("", result.stdout + result.stderr)
    passed = len(re.findall(r"^PASSED ", whole, flags=re.MULTILINE))
    failed = len(re.findall(r"^(FAILED|ERROR) ", whole, flags=re.MULTILINE))
    skipped = len(re.findall(r"^(SKIPPED|XFAIL) ", whole, flags=re.MULTILINE))
    # Some suites (Django's runner, older pytest) do not emit the per-test lines. Falling
    # back to the exit status there is right, but it is recorded as a fallback so a
    # surprising number can be traced to which rule produced it.
    basis, scoreable = "per-test lines", True
    if result.returncode == 4:
        # pytest could not make sense of the target — often a unittest-style id it cannot
        # collect. That says nothing about the code, and counting it as a failure would put
        # "could not be scored" into the denominator as "did not solve it". `tools._verdict`
        # reads the same status the same way, so the loop and the scorer agree.
        basis, scoreable = "pytest rejected the target (exit 4)", False
    elif passed == 0 and failed == 0 and skipped == 0:
        # No per-test lines at all. The exit status is the only evidence left, and it is
        # weaker than the rule above it — pytest exits zero when everything was skipped — so
        # the episode is marked unscoreable and excluded rather than counted on trust.
        basis, scoreable = "exit status only, no per-test lines", False
        passed = len(tests) if result.returncode == 0 else 0
    return {
        "ran": len(tests),
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "ok": result.returncode == 0 and passed >= len(tests),
        "scoreable": scoreable,
        "returncode": result.returncode,
        "basis": basis,
        "detail": whole[-1200:],
    }


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

    fail_to_pass = pytest_outcome(tuple(instance["fail_to_pass"]), timeout=args.timeout)
    pass_to_pass = pytest_outcome(tuple(instance["pass_to_pass"]), timeout=args.timeout)
    scoreable = fail_to_pass.get("scoreable", True) and pass_to_pass.get("scoreable", True)
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
    if not scoreable:
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
