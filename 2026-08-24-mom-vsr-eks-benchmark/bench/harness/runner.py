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
"""

from __future__ import annotations

import asyncio
import json
import random
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Sequence

import aiohttp

from . import client, dataset, score


@dataclass(frozen=True)
class Task:
    """One cell of the run: ask this arm this question."""

    arm: str
    model: str
    item: dataset.Item


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


class _Unbounded:
    """A gate that admits everyone, for members with no limit of their own."""

    async def __aenter__(self) -> None:
        return None

    async def __aexit__(self, *_exc: object) -> None:
        return None


_UNBOUNDED = _Unbounded()


def cell_key(arm: str, question_id: str) -> str:
    return f"{arm}\t{question_id}"


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
            done.add(cell_key(row["arm"], row["question_id"]))
    return done


def plan(
    tasks: Iterable[Task], *, seed: int, skip: set[str] | None = None
) -> list[Task]:
    """Shuffle the cross product so arm and time are not confounded."""
    remaining = [
        task
        for task in tasks
        if not skip or cell_key(task.arm, task.item.question_id) not in skip
    ]
    rng = random.Random(seed)
    rng.shuffle(remaining)
    return remaining


def pinned_tasks(items: Sequence[dataset.Item], model_names: Sequence[str]) -> list[Task]:
    """Every member answers every question: the matrix all the offline arms need."""
    return [
        Task(arm=f"pinned:{name}", model=name, item=item)
        for item in items
        for name in model_names
    ]


def repeat_tasks(items: Sequence[dataset.Item], model_names: Sequence[str]) -> list[Task]:
    """Ask the same members the same questions a second time.

    The matrix holds one sample per cell, and no temperature was sent, so a member
    decodes at its own default and is not guaranteed to be deterministic. That
    matters most for the existential bound, which is a chain of "did anyone get this
    right" and therefore rises with any independent flipping. Measuring the flip
    rate on a subset is what turns that from an unquantified worry into a number.
    """
    return [
        Task(arm=f"repeat:{name}", model=name, item=item)
        for item in items
        for name in model_names
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
) -> dict[str, int]:
    """Execute tasks with bounded concurrency, appending records as they finish."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    semaphore = asyncio.Semaphore(config.concurrency)
    per_model = {
        name: asyncio.Semaphore(limit) for name, limit in config.per_model_concurrency
    }
    write_lock = asyncio.Lock()
    stats = {"ok": 0, "failed": 0, "unparsed": 0}
    extra_headers = (
        {"authorization": f"Bearer {config.api_key}"} if config.api_key else {}
    )

    with out_path.open("a") as sink:

        async def one(session: aiohttp.ClientSession, task: Task) -> None:
            member_gate = per_model.get(task.model, _UNBOUNDED)
            async with semaphore, member_gate:
                record = await client.call_once(
                    session,
                    config.url,
                    arm=task.arm,
                    model=task.model,
                    prompt=task.item.prompt,
                    item_id=task.item.question_id,
                    dataset=task.item.dataset,
                    category=task.item.category,
                    fold=task.item.fold,
                    max_tokens=config.max_tokens,
                    temperature=config.temperature,
                    max_attempts=config.max_attempts,
                    timeout_s=config.timeout_s,
                    extra_headers=extra_headers,
                )
            if record.error is None:
                graded = score.grade(record.text, task.item.question, config.bench_root)
                record.extracted = graded.extracted
                record.correct = graded.correct
                if not graded.parsed:
                    stats["unparsed"] += 1
                stats["ok"] += 1
            else:
                stats["failed"] += 1

            async with write_lock:
                sink.write(json.dumps(record.to_json(), ensure_ascii=False) + "\n")
                sink.flush()
            if on_record:
                on_record(record)

        connector = aiohttp.TCPConnector(limit=config.concurrency + 4)
        async with aiohttp.ClientSession(connector=connector) as session:
            await asyncio.gather(*(one(session, task) for task in tasks))

    return stats
