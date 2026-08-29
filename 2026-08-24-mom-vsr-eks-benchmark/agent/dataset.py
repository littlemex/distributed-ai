"""Which SWE-bench Verified instances an episode run uses, and why those.

The 500 instances are not a population to sample uniformly. Django is 231 of them — 46% —
and a uniform draw would answer "how well do these models fix Django", which is not the
question. Difficulty is skewed the same way: 455 of 500 are labelled under an hour.

So the pilot subset is stratified on both, with a fixed seed, and the strata are written
down here rather than chosen at run time. Anything else invites picking the subset after
seeing which instances the cheap model happens to pass.
"""

from __future__ import annotations

import json
import random
import urllib.request
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

ROWS_API = (
    "https://datasets-server.huggingface.co/rows"
    "?dataset=princeton-nlp%2FSWE-bench_Verified&config=default&split=test"
    "&offset={offset}&length={length}"
)
TOTAL = 500

# The labels the dataset uses, in the order a person would rank them.
DIFFICULTIES = ("<15 min fix", "15 min - 1 hour", "1-4 hours", ">4 hours")


@dataclass(frozen=True)
class Instance:
    """One task: a repository at a commit, a complaint, and the tests that judge it."""

    instance_id: str
    repo: str
    base_commit: str
    environment_setup_commit: str
    problem_statement: str
    difficulty: str
    fail_to_pass: tuple[str, ...]
    pass_to_pass: tuple[str, ...]
    gold_patch: str
    test_patch: str

    @property
    def image(self) -> str:
        """The official evaluation image, which is the only authoritative environment.

        Reproducing a repository's test dependencies by hand is a way to measure the
        reproduction rather than the model.
        """
        return f"swebench/sweb.eval.x86_64.{self.instance_id.replace('__', '_1776_')}:latest"


def _rows(cache: Path | None) -> list[dict]:
    if cache and cache.exists():
        return json.loads(cache.read_text())
    out: list[dict] = []
    for offset in range(0, TOTAL, 100):
        with urllib.request.urlopen(
            ROWS_API.format(offset=offset, length=100), timeout=120
        ) as response:
            out += [row["row"] for row in json.load(response)["rows"]]
    if cache:
        cache.write_text(json.dumps(out))
    return out


def load(cache: Path | None = None) -> list[Instance]:
    return [
        Instance(
            instance_id=row["instance_id"],
            repo=row["repo"],
            base_commit=row["base_commit"],
            environment_setup_commit=row["environment_setup_commit"],
            problem_statement=row["problem_statement"],
            difficulty=row["difficulty"],
            fail_to_pass=tuple(json.loads(row["FAIL_TO_PASS"])),
            pass_to_pass=tuple(json.loads(row["PASS_TO_PASS"])),
            gold_patch=row["patch"],
            test_patch=row["test_patch"],
        )
        for row in _rows(cache)
    ]


def stratified(
    instances: list[Instance], *, size: int, seed: int = 20260826
) -> list[Instance]:
    """A subset that keeps every repository and difficulty represented.

    Proportional allocation would hand almost half the subset to one repository, so each
    stratum is drawn round-robin instead: the rarer a repository is, the more it is
    over-represented relative to the corpus, which is what makes a per-repository reading
    possible at all. Deterministic in `seed`, so the subset is a decision made once.
    """
    strata: dict[tuple[str, str], list[Instance]] = defaultdict(list)
    for instance in instances:
        strata[(instance.repo, instance.difficulty)].append(instance)
    rng = random.Random(seed)
    for bucket in strata.values():
        rng.shuffle(bucket)

    order = sorted(strata, key=lambda key: (key[0], DIFFICULTIES.index(key[1])))
    picked: list[Instance] = []
    while len(picked) < size:
        took = False
        for key in order:
            if strata[key]:
                picked.append(strata[key].pop())
                took = True
                if len(picked) == size:
                    break
        if not took:
            break  # the corpus is exhausted before the requested size
    return sorted(picked, key=lambda i: i.instance_id)


def summarise(instances: list[Instance]) -> str:
    by_repo: dict[str, int] = defaultdict(int)
    by_difficulty: dict[str, int] = defaultdict(int)
    for instance in instances:
        by_repo[instance.repo] += 1
        by_difficulty[instance.difficulty] += 1
    lines = [f"{len(instances)} instances over {len(by_repo)} repositories"]
    for difficulty in DIFFICULTIES:
        if by_difficulty.get(difficulty):
            lines.append(f"    {difficulty:<22}{by_difficulty[difficulty]:>4}")
    for repo, count in sorted(by_repo.items(), key=lambda kv: -kv[1]):
        lines.append(f"    {repo:<28}{count:>4}")
    return "\n".join(lines)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", type=int, default=24, help="pilot subset size")
    parser.add_argument("--cache", type=Path, default=None)
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    everything = load(args.cache)
    print("corpus:")
    print(summarise(everything))
    subset = stratified(everything, size=args.size)
    print("\nsubset:")
    print(summarise(subset))
    if args.out:
        args.out.write_text(
            json.dumps([i.instance_id for i in subset], ensure_ascii=False, indent=2)
        )
        print(f"\n[OK] ids -> {args.out}")
