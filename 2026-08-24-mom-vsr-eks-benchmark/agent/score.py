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

The scorer never sees the gold patch. It exists in the instance data for the smoke test
that proves this environment can distinguish a fix from no fix at all.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

TESTBED = Path("/testbed")
CONDA_ACTIVATE = "source /opt/miniconda3/etc/profile.d/conda.sh && conda activate testbed"
# One test file's failures should not hide another's, and a repository's suite can be long.
DEFAULT_TIMEOUT = 1800


def run(command: str, *, timeout: int = DEFAULT_TIMEOUT) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["/bin/bash", "-lc", f"cd {TESTBED} && {CONDA_ACTIVATE} && {command}"],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def touched_tests(diff: str) -> list[str]:
    """Files in the agent's diff that look like part of the examination."""
    paths = re.findall(r"^\+\+\+ b/(.+)$", diff, flags=re.MULTILINE)
    return [
        path
        for path in paths
        if re.search(r"(^|/)(tests?|testing)/", path) or re.match(r".*test_[^/]*\.py$", path)
    ]


def pytest_outcome(tests: tuple[str, ...], *, timeout: int) -> dict:
    """Run named tests and report what happened, without interpreting silence as success."""
    if not tests:
        return {"ran": 0, "passed": 0, "failed": 0, "ok": True, "detail": "no tests named"}
    quoted = " ".join(f'"{test}"' for test in tests)
    result = run(f"python -m pytest {quoted} -rA -q", timeout=timeout)
    tail = (result.stdout + result.stderr)[-4000:]
    passed = len(re.findall(r"^PASSED ", tail, flags=re.MULTILINE)) or (
        len(tests) if result.returncode == 0 else 0
    )
    failed = len(re.findall(r"^(FAILED|ERROR) ", tail, flags=re.MULTILINE))
    return {
        "ran": len(tests),
        "passed": passed,
        "failed": failed,
        "ok": result.returncode == 0,
        "returncode": result.returncode,
        "detail": tail[-1200:],
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
    verdict.update(
        fail_to_pass=fail_to_pass,
        pass_to_pass=pass_to_pass,
        resolved=bool(fail_to_pass["ok"] and pass_to_pass["ok"]),
    )
    args.out.write_text(json.dumps(verdict, indent=2))
    print(
        f"[{'OK' if verdict['resolved'] else 'FAIL'}] {instance['instance_id']}: "
        f"fail_to_pass={'pass' if fail_to_pass['ok'] else 'fail'} "
        f"pass_to_pass={'pass' if pass_to_pass['ok'] else 'fail'}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
