# Episode harness

One episode is one SWE-bench Verified instance attempted by one policy, in the official
evaluation image, scored by the repository's own tests. What v3 measures is the cost of
solving a task, so the unit here is a task and not a call.

```
dataset.py    which instances a run uses, and the stratified pilot subset
tools.py      what the agent can do to the repository, and what each action is a step of
policy.py     who takes the next step, why, and what it cost — no network, no container
transport.py  one model call, on the standard library only
loop.py       the driver: runs an episode and writes what it spent
score.py      runs after the loop: decides resolved / not, and refuses a cheat
run.sh        submits one episode as a Job in the instance's own image
tests/        the decisions that would produce a plausible wrong number if they were wrong
```

## Why the official image

Reproducing a repository's test dependencies by hand measures the reproduction. Each
instance has an image on Docker Hub — `swebench/sweb.eval.x86_64.<instance_id>` with the
double underscore spelled `_1776_` — carrying `/testbed` at the base commit and a conda
environment that can already run the suite. They are about 1.0–1.3 GB each.

The loop runs inside that image and speaks HTTP with the standard library, because
installing a package into the image would change the environment the result is attributed
to. The agent's tools shell into the repository's own conda environment; the loop itself
runs on the base interpreter.

## The scoring contract, in the order it has to happen

1. The agent works on `/testbed` and **never sees the tests that judge it**. The test patch
   is applied by `score.py` after the agent's diff has been captured; an agent that can read
   the test knows the answer.
2. A diff that edits a test file **fails the episode** — and "test file" includes
   `conftest.py`, `pytest.ini` and the rest, because a `conftest.py` that skips everything
   makes pytest exit zero and would read as a fix.
3. `FAIL_TO_PASS` must pass and `PASS_TO_PASS` must still pass, and *pass* means every named
   test reported PASSED, not merely that pytest exited zero. The second half is what
   separates a fix from a change that breaks the library, and it is most of the test time.
4. The checkout is reset before anything is applied. The episode ran in this container and
   left its edits in place, so re-applying its own diff would fail — most reliably for a
   *correct* fix, which is the one that applied cleanly the first time.

## The two mechanisms, which have nothing in common

`docs/SWITCH-ECONOMICS.md` measured the switch tax: handing a conversation to a model that
has never seen it means paying fresh input for the whole accumulated prefix. One escalation
in a sixty-step session saves 63%; eight spot escalations cost 33% *more* than never leaving
the premium model. So:

**Escalation** (`cheap-then-escalate`) moves the thread, once, and never back. The latch is
in code. The tax is measured on the first premium turn — charged on the prefix as it stood
*before* that turn, since the turn's own new material would have been fresh anyway.

**Handoff** (`role-based`) does not move the thread at all. The role table assigns each step
type to a tier; a tool whose step type sits above the worker is not offered to it, so when
the worker is ready it hands off and the premium model receives a fresh, self-contained
request — the report, the worker's findings, and the files the worker read. There is no
prefix to re-establish, so unlike escalation this can happen more than once, and afterwards
the worker resumes and can test the patch. That last part is what keeps the arm on the same
footing as the others rather than being the only one judged on an untested fix.

The role table is load-bearing rather than decorative: `tools_above()` derives what is
withheld from it, so changing `verify` to the premium tier moves `run_tests` too.

## The triggers

All three are computable from the log with no extra model call:

1. a test failing **after the agent has changed something** — before any edit, a failing
   test is the reported bug, not a disagreement with the agent's work;
2. the same action repeated k times, where a different edit to the same file is a different
   action and paging further through a file is not;
3. a fraction of the step or token budget, named in `Budget` so the trigger's own name
   cannot come to lie about what it measures.

Self-reported confidence is excluded, and so is cheap-model disagreement: v1 measured strong
arms' errors as highly correlated, so it would rarely fire and would agree when wrong, at
the cost of a second full context every time it was consulted.

## What is deliberately not an experimental condition

`max_steps` and `max_tokens` are the same for every policy, which is what makes the
comparison paired. The **dollar ceiling is not**: a single ceiling binds the premium
baseline first by construction, so an episode that hits it would hand the non-inferiority
claim a free win. It is a runaway guard set well above any expected episode, and an episode
that reaches it is recorded `comparable: false` with the reason — a pre-registered exclusion
rather than a judgement made after seeing which arm hit it.

## Where a flattering number could have come from

Each of these is now closed, and each is tested:

| Route | What it would have done |
| --- | --- |
| the diff swept in the image's untracked `build/` tree | an 867 KB "patch" that applies nowhere — every episode fails |
| only the last action in a turn was executed | a model that sent its patch and its `done` together was scored as having done nothing |
| abandoned retry attempts reported no cost | discounts the tiers whose streams break most, which are the cheap ones |
| a broken stream carried no usage block | a free step that also slips past the spend ceiling; long streams break most |
| cache writes counted as fresh input as well | double-charges only the long-lived threads, which is the baseline |
| a transport failure counted as the model failing to follow the format | withdraws a tier for the network's behaviour |
| the handoff was offered every tool but only accepted patches | a model that obediently opened with a read produced an episode with no patch |
| the handoff bypassed the budget check | one policy with a budget the others do not have |
| an unreadable in-flight count read the same as a full machine | `capacity-first` silently becomes `cheap-always` |
| `conftest.py` was not a test file | skip everything, exit zero, resolved |
| a suite that timed out raised instead of scoring | the hardest instances vanish from a denominator |

## The pilot subset

`python dataset.py --size 24` selects it. The corpus is 500 instances over 12 repositories,
but 231 of them are Django and 455 are labelled under an hour, so a uniform draw would
answer "how well do these models fix Django". The subset is drawn round-robin over
(repository, difficulty) strata with a fixed seed, which over-represents the rare
repositories on purpose and makes a per-repository reading possible.

The 24 selected: 10 repositories, all four difficulty bands (9 under 15 minutes, 9 up to an
hour, 5 up to four hours, 1 beyond). Django is 3 rather than the 11 a proportional draw
would give.

## Running one

```bash
export KUBE_CONTEXT=<context>
export STRATOCLAVE_HOST=<gateway host>
export STRATOCLAVE_API_KEY=<gateway bearer token>
export STRATOCLAVE_DEFAULTS=<gateway repo>/backend/mvp/defaults
./run.sh psf__requests-1142 premium-always
```

`tiers.example.json` says which model each tier is. Addresses are injected at submit time,
because a gateway host is a property of a deployment and not of the experiment. The
self-hosted tier states its own price and must say where the number came from: the rate
table prices its key at the top tier because Bedrock publishes no list price, and its generic
`vllm` key is $0.20 per million, which is neither the machine's cost nor anything measured.
