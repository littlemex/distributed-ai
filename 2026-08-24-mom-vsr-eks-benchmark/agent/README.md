# Episode harness

One episode is one SWE-bench Verified instance attempted by one policy, in the official
evaluation image, scored by the repository's own tests. What v3 measures is the cost of
solving a task, so the unit here is a task and not a call.

```
dataset.py    which instances a run uses, and the stratified pilot subset
score.py      runs inside the image: decides resolved / not, and refuses a cheat
tests/        the subset rules and the verdict rules
```

## Why the official image

Reproducing a repository's test dependencies by hand measures the reproduction. Each
instance has an image on Docker Hub — `swebench/sweb.eval.x86_64.<instance_id>` with the
double underscore spelled `_1776_` — carrying `/testbed` at the base commit and a conda
environment that can already run the suite. They are about 1.0–1.3 GB each.

## The scoring contract, in the order it has to happen

1. The agent works on `/testbed` and **never sees the tests that judge it**. The test patch
   is applied by `score.py` after the agent's diff has been captured; an agent that can read
   the test knows the answer.
2. A diff that edits a test file **fails the episode**. That is the most likely way for a run
   to produce a flattering number, so it is detected rather than trusted.
3. `FAIL_TO_PASS` must pass and `PASS_TO_PASS` must still pass. The second half is what
   separates a fix from a change that breaks the library, and it is most of the test time —
   a median instance has 1 test in the first set and 50 in the second.

## Validated, before any model was involved

Run on `psf__requests-1142` in its own image:

| Input | Verdict | |
| --- | --- | --- |
| the reference patch | resolved | `fail_to_pass=pass pass_to_pass=pass` |
| no patch at all | not resolved | `fail_to_pass=fail` — the discriminating case |
| a patch editing `test_requests.py` | refused | reported as editing test files |

The middle row is the one that matters: an environment where the failing test does not fail
without the fix cannot measure anything, and that is checked rather than assumed.

## The pilot subset

`python dataset.py --size 24` selects it. The corpus is 500 instances over 12 repositories,
but 231 of them are Django and 455 are labelled under an hour, so a uniform draw would
answer "how well do these models fix Django". The subset is drawn round-robin over
(repository, difficulty) strata with a fixed seed, which over-represents the rare
repositories on purpose and makes a per-repository reading possible.

The 24 selected today: 10 repositories, and all four difficulty bands (9 under 15 minutes,
9 up to an hour, 5 up to four hours, 1 beyond). Django is 3 rather than the 11 a proportional
draw would give.

## Not built yet

The agent loop: the tools it gets, the step types it labels its own work with, the
escalation triggers, and the policies from `docs/V3-PLAN.md` (premium throughout, cheap
throughout, cheap with one-way escalation, capacity-first, role-based). The two things that
had to be true before any of that was worth writing — that the environment can tell a fix
from no fix, and that a subset exists which is not mostly Django — are now true.
