"""Execute a set of (question, arm) calls and write one JSONL row per call.

Two properties of the execution order are load-bearing, and neither is an
optimisation:

* **Interleaved, not arm-by-arm.** Upstream providers drift over hours, model
  aliases can be updated underneath us, and a token balance drains as the run
  proceeds. Running one arm to completion before starting the next would put all
  of those effects in the between-arm comparison, which is exactly the comparison
  the benchmark exists to make. So the unit of work is a single call, and the
  whole cross product is shuffled with a fixed seed before execution.

* **Concurrency per member, not per run.** One member is a self-hosted vLLM
  serving two sequences, so load above that queues inside its pod and is recorded
  as the model being slow. A single run-wide limit would have to be that small for
  everyone, which turns a two-hour matrix into a fifteen-hour one because one
  reasoning member answers in twenty seconds. So each member gets its own limit
  and the run-wide limit only caps the total in flight. Throughput remains a
  separate experiment with its own load control.

Results stream to disk as they complete. A run that dies halfway leaves a usable
partial matrix, and `--resume` skips the cells already present rather than paying
for them twice.

The unit of comparison is an arm — a member at one reasoning effort — and not a
member, so one member can appear in several cells of the same run. Two
consequences are wired in here rather than left to the caller. Requests are sent
on the streaming path, because the gateway caps a non-streaming read at fifty
seconds and a high effort level exceeds it, which would silently delete the
arms the effort axis exists to measure. And an arm whose effort level the
provider rejects is retired for the rest of the run: it has ceased to exist, so
paying for the remaining questions would buy a shorter arm that is not
comparable with the others.
"""

from __future__ import annotations

import asyncio
import json
import random
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, Sequence

import aiohttp

from . import catalog, client, dataset, score


@dataclass(frozen=True)
class Task:
    """One cell of the run: ask this arm this question.

    `effort` is what goes in the request body, and `None` means the field is
    omitted — a distinct setting from any value, and the only one the whole pool
    accepts. `arm` already carries the effort in its name, so the recorded rows
    stay one flat namespace.
    """

    arm: str
    model: str
    item: dataset.Item
    effort: str | None = None


@dataclass(frozen=True)
class RunConfig:
    url: str
    max_tokens: int
    temperature: float | None
    concurrency: int
    max_attempts: int
    timeout_s: float
    shuffle_seed: int
    api_key: str | None = None
    bench_root: Path | None = None
    # Model name -> its own in-flight limit. A member absent from this map is
    # bounded only by `concurrency`.
    per_model_concurrency: tuple[tuple[str, int], ...] = ()
    # On for every arm or off for every arm. Mixing the two inside one run would
    # put the streaming path's own latency into the between-arm comparison, and
    # only the streaming path can carry a slow arm past the gateway's
    # non-streaming read window.
    stream: bool = True
    # How long a stream may go silent before it is treated as dead. On the streaming
    # path these replace the total deadline, because total duration is what the
    # high-effort arms are being measured on: `stream_idle_s` between events once the
    # stream has started, a far looser `stream_first_event_s` before the first one
    # because a provider that buffers its thinking sends nothing while it works, and
    # `stream_ceiling_s` so that no single call can hold a slot indefinitely.
    stream_idle_s: float = 90.0
    stream_first_event_s: float = 600.0
    stream_ceiling_s: float = 1800.0


@dataclass
class RunStats:
    """What a run produced, including the arms that stopped existing during it.

    The counters are mutated from inside the run's tasks without a lock, which is
    safe because those tasks are coroutines on one event loop and none of them
    yields between reading and writing. Moving the runner onto threads would make
    every one of these a race.
    """

    ok: int = 0
    failed: int = 0
    unparsed: int = 0
    # Cells not attempted because their arm had already been rejected.
    skipped: int = 0
    retired_arms: dict[str, str] = field(default_factory=dict)
    # Per arm, this run's scored calls and how many of them the completion budget
    # stopped. Counted as the calls come back rather than read from the file
    # afterwards: the file may hold earlier runs measured at a different budget,
    # and mixing those into the rate would hide exactly what the rate is for.
    scored_by_arm: dict[str, int] = field(default_factory=dict)
    truncated_by_arm: dict[str, int] = field(default_factory=dict)
    # Failures per arm, not just the run's total. The paired design assumes every arm
    # was asked every question, and a transient outage that lands on one arm breaks
    # that assumption without changing the run's total by much. A failed cell counts
    # as collected, so the loss is permanent unless someone sees it here.
    failed_by_arm: dict[str, int] = field(default_factory=dict)

    def failure_asymmetry(self) -> dict[str, float]:
        """Per arm, the share of its attempted cells that failed.

        Reported for every arm rather than only the worst, because the number that
        matters is the spread: arms failing alike costs power, one arm failing alone
        costs comparability.
        """
        rates = {}
        for arm in set(self.failed_by_arm) | set(self.scored_by_arm):
            failed = self.failed_by_arm.get(arm, 0)
            attempted = failed + self.scored_by_arm.get(arm, 0)
            if attempted:
                rates[arm] = failed / attempted
        return rates

    def truncation_rates(self) -> dict[str, dict[str, float]]:
        """Per arm, how often the completion budget was the thing that stopped it.

        The budget is a cap and not a charge: raising it costs nothing for an arm
        that stops at two hundred tokens, and only the arms that use it pay. What it
        does change is scoring, because an arm cut off mid-sentence is graded as
        wrong for running out of room rather than for being wrong. So the budget is
        chosen by this number — raised until truncation is rare for every arm.
        """
        return {
            arm: {
                "scored": scored,
                "truncated": self.truncated_by_arm.get(arm, 0),
                "rate": self.truncated_by_arm.get(arm, 0) / scored if scored else 0.0,
            }
            for arm, scored in self.scored_by_arm.items()
        }


# The thresholds that turn these counters into "this run cannot be compared" live in
# `harness.quality`: counting is the runner's job, and the line between a worse arm and
# a differently measured one is measurement policy that the analysis needs too.


class _Unbounded:
    """A gate that admits everyone, for members with no limit of their own."""

    async def __aenter__(self) -> None:
        return None

    async def __aexit__(self, *_exc: object) -> None:
        return None


_UNBOUNDED = _Unbounded()


def cell_key(arm: str, question_id: str, dataset: str = "") -> str:
    """Identity of one cell. The dataset is part of it because question ids are not
    unique across corpora, and the plan is for benchmarks to plug in: two datasets
    sharing an id would silently mark each other's cells as collected."""
    return f"{arm}\t{dataset}\t{question_id}"


def completed_cells(path: Path) -> set[str]:
    """Cells already recorded, so a resumed run does not re-pay for them.

    A row that failed is treated as complete. Silently retrying failures on
    resume would give a question more attempts in one arm than another, and the
    failure rate is itself a reported number.
    """
    done: set[str] = set()
    if not path.exists():
        return done
    with path.open() as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            done.add(cell_key(row["arm"], row["question_id"], row.get("dataset", "")))
    return done


def retired_arms(path: Path) -> dict[str, str]:
    """Arms an earlier run found do not exist, read back from the results file.

    Retirement has to survive the process. It is a fact about the provider, not about
    one run, and the file already holds the evidence: the row whose request was
    refused. Without reading it back, a resumed run re-attempts every remaining
    question of an arm that is known to be gone and pays a 400 for each one — the
    money the retirement logic exists to save, given away one process restart later.
    """
    gone: dict[str, str] = {}
    if not path.exists():
        return gone
    with path.open() as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("arm_unsupported"):
                gone.setdefault(row["arm"], row.get("error") or "rejected earlier")
    return gone


def settings_conflict(path: Path, config: RunConfig) -> str | None:
    """Why appending this run to an existing file would corrupt the comparison.

    A run always appends, and a resumed one skips the cells already there, so the
    file can end up holding cells measured under two different settings. The arm
    name does not protect against it: a default-effort arm in v2 is spelled exactly
    as the same member was in v1, while having been measured on the non-streaming
    path at an eighth of the completion budget. Mixing those makes the arm's
    latency, its truncation rate and part of its accuracy artefacts of when it was
    collected — and the effort axis is precisely a comparison between a member's
    default arm and its own higher levels.

    A row missing any of the fields is treated as unknown rather than as a match: the
    rows that predate them are exactly the ones that would be mixed in.

    Not defended here: two processes appending to one file. The check happens before
    the first write and nothing holds a lock, so concurrent runs to the same path both
    pass it. One run per file.
    """
    if not path.exists():
        return None
    # The request fields that change what the model does, and so what its accuracy and
    # cost mean. Censoring settings are checked separately: they change which calls
    # survive rather than what a surviving call is.
    checked = {"stream": config.stream, "max_tokens": config.max_tokens,
               "temperature": config.temperature}
    seen: dict[str, set] = {name: set() for name in checked}
    unlabelled = 0
    with path.open() as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if any(name not in row for name in checked):
                unlabelled += 1
                continue
            for name in checked:
                seen[name].add(row.get(name))
    if unlabelled:
        return (
            f"{path} holds {unlabelled} rows from before the request settings were "
            "recorded, so whether they were measured the same way cannot be checked. "
            "Write this run to a new file."
        )
    mismatched = [
        f"{name}={sorted(values, key=str)} (this run: {checked[name]})"
        for name, values in sorted(seen.items())
        if values - {checked[name]}
    ]
    if mismatched:
        return (
            f"{path} was collected with different request settings: "
            + "; ".join(mismatched)
            + ". Appending would put the difference between two settings inside the "
            "comparison between two arms. Write this run to a new file, or match the "
            "recorded settings."
        )
    return None


def censoring_drift(path: Path, config: RunConfig) -> str | None:
    """Whether this run would cut slow calls at a different point than the file did.

    A different idle deadline does not change what a completed call means, so it is
    not a reason to refuse the file. It does change *which* calls complete, and the
    arms it changes that for are the slow ones — so a file collected under two
    deadlines has a failure and truncation profile that is partly a function of when
    each row was collected.
    """
    if not path.exists() or not config.stream:
        return None
    idles: set = set()
    firsts: set = set()
    with path.open() as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("stream"):
                idles.add(row.get("stream_idle_s"))
                firsts.add(row.get("stream_first_event_s"))
    drifted = []
    if idles - {config.stream_idle_s}:
        drifted.append(
            f"stream_idle_s={sorted(idles, key=str)} (this run: {config.stream_idle_s})"
        )
    if firsts - {config.stream_first_event_s}:
        drifted.append(
            f"stream_first_event_s={sorted(firsts, key=str)} "
            f"(this run: {config.stream_first_event_s})"
        )
    if drifted:
        return (
            f"{path} was collected with " + "; ".join(drifted) + ". Completed calls stay "
            "comparable, but which slow calls survive does not, so the failure and "
            "truncation rates in this file will be a mix of two censoring points."
        )
    return None


def plan(
    tasks: Iterable[Task], *, seed: int, skip: set[str] | None = None
) -> list[Task]:
    """Shuffle the cross product so arm and time are not confounded."""
    remaining = [
        task
        for task in tasks
        if not skip
        or cell_key(task.arm, task.item.question_id, task.item.dataset) not in skip
    ]
    rng = random.Random(seed)
    rng.shuffle(remaining)
    return remaining


def pinned_tasks(items: Sequence[dataset.Item], arms: Sequence[catalog.Arm]) -> list[Task]:
    """Every arm answers every question: the matrix all the offline policies need."""
    return [
        Task(
            arm=f"pinned:{arm.name}",
            model=arm.member.name,
            item=item,
            effort=arm.request_effort,
        )
        for item in items
        for arm in arms
    ]


def repeat_tasks(items: Sequence[dataset.Item], arms: Sequence[catalog.Arm]) -> list[Task]:
    """Ask the same members the same questions a second time.

    The matrix holds one sample per cell, and no temperature was sent, so a member
    decodes at its own default and is not guaranteed to be deterministic. That
    matters most for the existential bound, which is a chain of "did anyone get this
    right" and therefore rises with any independent flipping. Measuring the flip
    rate on a subset is what turns that from an unquantified worry into a number.
    """
    return [
        Task(
            arm=f"repeat:{arm.name}",
            model=arm.member.name,
            item=item,
            effort=arm.request_effort,
        )
        for item in items
        for arm in arms
    ]


def routed_tasks(items: Sequence[dataset.Item], entrypoint: str, arm: str) -> list[Task]:
    """The router chooses. One call per question."""
    return [Task(arm=arm, model=entrypoint, item=item) for item in items]


async def run(
    tasks: Sequence[Task],
    config: RunConfig,
    out_path: Path,
    *,
    on_record: Callable[[client.Call], None] | None = None,
    already_retired: dict[str, str] | None = None,
) -> RunStats:
    """Execute tasks with bounded concurrency, appending records as they finish.

    `already_retired` carries forward what an earlier run learned about arms the
    provider refuses, so a resumed run does not buy the same 400 once per question.
    """
    out_path.parent.mkdir(parents=True, exist_ok=True)
    semaphore = asyncio.Semaphore(config.concurrency)
    per_model = {
        name: asyncio.Semaphore(limit) for name, limit in config.per_model_concurrency
    }
    # Until an arm has come back once, only one of its calls is allowed out. An arm
    # whose effort level does not exist is discovered by the first response, and every
    # call sent before that response arrives is a 400 that was paid for; scheduling
    # the whole cross product at once means that would otherwise be a slotful of them.
    # The gate costs one serialised call per arm at the start of a run.
    unproven_gate = {task.arm: asyncio.Semaphore(1) for task in tasks}
    proven: set[str] = set()
    write_lock = asyncio.Lock()
    stats = RunStats(retired_arms=dict(already_retired or {}))
    if stats.retired_arms:
        proven.update(stats.retired_arms)
    extra_headers = (
        {"authorization": f"Bearer {config.api_key}"} if config.api_key else {}
    )

    with out_path.open("a") as sink:

        async def one(session: aiohttp.ClientSession, task: Task) -> None:
            # An arm the provider has already rejected is not retried on the next
            # question. The first rejection is recorded and is the evidence; the
            # rest would be the same 400 at the same price in wall-clock.
            if task.arm in stats.retired_arms:
                stats.skipped += 1
                return
            member_gate = per_model.get(task.model, _UNBOUNDED)
            async with semaphore, member_gate:
                # Checked again with the slot in hand. The whole task list is
                # scheduled at once, so most cells pass the check above long before
                # the rejection arrives; without this the queue would drain into the
                # dead arm anyway. What cannot be avoided is the calls already in
                # flight when the rejection lands, which is at most the concurrency.
                if task.arm in stats.retired_arms:
                    stats.skipped += 1
                    return

                async def ask() -> client.Call:
                    return await client.call_once(
                        session,
                        config.url,
                        stream=config.stream,
                        arm=task.arm,
                        model=task.model,
                        prompt=task.item.prompt,
                        item_id=task.item.question_id,
                        dataset=task.item.dataset,
                        category=task.item.category,
                        fold=task.item.fold,
                        max_tokens=config.max_tokens,
                        temperature=config.temperature,
                        reasoning_effort=task.effort,
                        max_attempts=config.max_attempts,
                        timeout_s=config.timeout_s,
                        stream_idle_s=config.stream_idle_s,
                        stream_first_event_s=config.stream_first_event_s,
                        stream_ceiling_s=config.stream_ceiling_s,
                        extra_headers=extra_headers,
                    )

                if task.arm in proven:
                    record = await ask()
                else:
                    async with unproven_gate[task.arm]:
                        # Re-checked twice over: the arm may have been retired, or
                        # proven, while this call waited for the gate.
                        if task.arm in stats.retired_arms:
                            stats.skipped += 1
                            return
                        record = await ask()
                    proven.add(task.arm)
            if record.arm_unsupported:
                stats.retired_arms.setdefault(task.arm, record.error or "rejected")
            if record.error is None:
                graded = score.grade(record.text, task.item.question, config.bench_root)
                record.extracted = graded.extracted
                record.correct = graded.correct
                if not graded.parsed:
                    stats.unparsed += 1
                stats.ok += 1
                stats.scored_by_arm[task.arm] = stats.scored_by_arm.get(task.arm, 0) + 1
                if record.finish_reason == "length":
                    stats.truncated_by_arm[task.arm] = (
                        stats.truncated_by_arm.get(task.arm, 0) + 1
                    )
            else:
                stats.failed += 1
                stats.failed_by_arm[task.arm] = stats.failed_by_arm.get(task.arm, 0) + 1

            async with write_lock:
                sink.write(json.dumps(record.to_json(), ensure_ascii=False) + "\n")
                sink.flush()
            if on_record:
                on_record(record)

        connector = aiohttp.TCPConnector(limit=config.concurrency + 4)
        async with aiohttp.ClientSession(connector=connector) as session:
            await asyncio.gather(*(one(session, task) for task in tasks))

    return stats
