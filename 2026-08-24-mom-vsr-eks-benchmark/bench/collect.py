#!/usr/bin/env python3
"""Collect measurements for the Mixture-of-Models benchmark.

    ./collect.py plan     --fold calibration --samples 4      # what a run would cost
    ./collect.py classify --fold calibration                  # free: decisions only
    ./collect.py matrix   --fold calibration --samples 4      # every member, every question
    ./collect.py routed   --fold test --arm multi_factor      # the router decides

Addresses and credentials come from the environment, never from flags, so a
command line is safe to paste into a report:

    VSR_URL           the router's OpenAI-compatible endpoint
    VSR_CLASSIFY_URL  the router's classification API
    VSR_BENCH_ROOT    the upstream semantic-router bench/ directory
    STRATOCLAVE_DEFAULTS  the gateway's models.json / pricing.json directory
    STRATOCLAVE_API_KEY   forwarded as the bearer token if the router expects one
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from harness import catalog, classify, dataset, quality, runner  # noqa: E402

DEFAULT_POOL = HERE.parent / "vsr" / "pool.yaml"
DEFAULT_RESULTS = HERE / "results"

# Every arm gets the same completion budget, which is what makes the accuracies
# comparable at all. The number is measured, not preferred: on the same 40 calls,
# a budget of 64 left 4 of 10 members with no letter at all, 512 left 6 answers
# unparsed out of 40, and 2048 left 2. The arms that run out are the
# reasoning-capable ones, which either narrate before answering or spend the whole
# budget on hidden thinking tokens — so a tight budget does not measure knowledge,
# it measures verbosity and charges it as error.
#
# The 2048 that v1 used was calibrated on default-effort arms only, and the effort
# probe showed it binding hard at the top of the dial: `grok-4.6` at `high` spent
# all 2048 on hidden reasoning and emitted no answer, and did the same at 4096. A
# budget is a cap and not a charge — an arm that stops at 200 tokens costs the same
# whatever the cap is, and only the arms that use it pay — so the cap is set high
# enough that truncation is rare for every arm, and the actual tokens remain the
# cost. Every run prints its per-arm truncation rate; that is the number to read
# before trusting a comparison, together with the per-arm unparsed rate.
DEFAULT_MAX_TOKENS = 16384

# Total in flight. Members that declare a limit of their own are held below it
# separately, so this number is about the gateway and not about the smallest
# member. The gateway sustains two orders of magnitude more than this; the value
# is chosen to keep one run's load off the shared cluster, not to find a ceiling.
DEFAULT_CONCURRENCY = 16


def env(name: str, *, required: bool = True, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if required and not value:
        raise SystemExit(f"[FAIL] environment variable {name} is required")
    return value or ""


def load_items(args: argparse.Namespace) -> list[dataset.Item]:
    os.environ.setdefault("VSR_BENCH_ROOT", env("VSR_BENCH_ROOT"))
    bench_root = Path(os.environ["VSR_BENCH_ROOT"])
    if str(bench_root) not in sys.path:
        sys.path.insert(0, str(bench_root))
    items = dataset.load_items(
        args.dataset,
        categories=args.categories,
        samples_per_category=args.samples,
        seed=args.seed,
        salt=args.salt,
    )
    if args.fold:
        items = dataset.in_fold(items, args.fold)
    return items


def members(args: argparse.Namespace) -> list[catalog.Member]:
    pool = args.pool or DEFAULT_POOL
    defaults = Path(env("STRATOCLAVE_DEFAULTS"))
    return catalog.only(catalog.load_pool(pool, defaults), getattr(args, "only", None))


def arms(args: argparse.Namespace, pool: list[catalog.Member]) -> list[catalog.Arm]:
    """The members expanded by the effort levels the pool declares.

    A member with no declaration gets the default level only, so the arm list is
    the v1 pool until the pool file says otherwise and adding a member never
    silently multiplies a run.
    """
    return catalog.arms(args.pool or DEFAULT_POOL, pool)


def cmd_plan(args: argparse.Namespace) -> int:
    """Report the shape and the price of a run before spending anything."""
    items = load_items(args)
    pool = members(args)
    arm_list = arms(args, pool)
    counts = dataset.fold_counts(items)
    print(f"[INFO] dataset={args.dataset} items={len(items)} fold={args.fold or 'all'}")
    print(f"[INFO] members={len(pool)} arms={len(arm_list)}")
    for member in pool:
        levels = [a.effort for a in arm_list if a.member.name == member.name]
        if len(levels) > 1:
            print(f"    {member.name:<30}{', '.join(levels)}")
    thin = {
        category: folds
        for category, folds in sorted(counts.items())
        if min(folds.values(), default=0) < args.thin_threshold
    }
    for category, folds in sorted(counts.items()):
        print(f"    {category:<24} " + ", ".join(f"{k}={v}" for k, v in sorted(folds.items())))
    if thin:
        print(
            f"[WARNING] {len(thin)} categories have a fold thinner than "
            f"{args.thin_threshold}; per-domain claims there will not be separable"
        )

    calls = len(items) * len(arm_list)
    print(f"[INFO] matrix calls: {len(items)} x {len(arm_list)} arms = {calls}")
    worst = catalog.worst_case_usd(arm_list, len(items), args.max_tokens)
    print(
        f"[INFO] ceiling at a {args.max_tokens}-token budget: ${worst['total']:.2f}. "
        "That is what it costs if every arm fills the budget, which reasoning arms can; "
        "run `matrix --samples 2` and multiply the measured mean for the likely figure"
    )
    return 0


def cmd_classify(args: argparse.Namespace) -> int:
    items = load_items(args)
    url = env("VSR_CLASSIFY_URL")
    out = args.out or args.out_dir / f"decisions-{args.fold or 'all'}.jsonl"
    decisions = asyncio.run(classify.classify_all(url, items, out, concurrency=args.concurrency))

    failed = [d for d in decisions if d.error]
    agreed = sum(1 for d in decisions if not d.error and args_true_label(d))
    scored = sum(1 for d in decisions if not d.error)
    print(f"[OK] {len(decisions)} classified -> {out}")
    if scored:
        print(f"[INFO] classifier agrees with the dataset category: {agreed}/{scored}")
    chosen: dict[str, int] = {}
    for decision in decisions:
        if decision.recommended_model:
            chosen[decision.recommended_model] = chosen.get(decision.recommended_model, 0) + 1
    for name, count in sorted(chosen.items(), key=lambda kv: -kv[1]):
        print(f"    would select {name:<28} {count}")
    if failed:
        print(f"[WARNING] {len(failed)} classification failures, first: {failed[0].error}")
    return 0


def args_true_label(decision: classify.Decision) -> bool:
    """Whether the classifier's matched domain is the dataset's own category."""
    return decision.category.lower() in {d.lower() for d in decision.matched_domains}


def member_gates(pool: list[catalog.Member]) -> tuple[tuple[str, int], ...]:
    """Per-member in-flight limits, taken from the pool's own declarations."""
    return tuple(
        (member.name, member.max_concurrent_sequences)
        for member in pool
        if member.max_concurrent_sequences
    )


def cmd_matrix(args: argparse.Namespace) -> int:
    items = load_items(args)
    pool = members(args)
    arm_list = arms(args, pool)
    out = args.out or args.out_dir / f"matrix-{args.fold or 'all'}.jsonl"
    skip = runner.completed_cells(out) if args.resume else set()
    tasks = runner.plan(
        runner.pinned_tasks(items, arm_list),
        seed=args.shuffle_seed,
        skip=skip,
    )
    if skip:
        print(f"[INFO] resuming: {len(skip)} cells already recorded")
    print(
        f"[INFO] {len(tasks)} calls over {len(arm_list)} arms at concurrency "
        f"{args.concurrency} -> {out}"
    )
    guard_spend(arm_list, len(items), args.max_tokens, args.max_spend_usd)

    config = runner.RunConfig(
        url=env("VSR_URL"),
        max_tokens=args.max_tokens,
        temperature=args.temperature,
        concurrency=args.concurrency,
        max_attempts=args.max_attempts,
        timeout_s=args.timeout,
        shuffle_seed=args.shuffle_seed,
        api_key=os.environ.get("STRATOCLAVE_API_KEY") or None,
        bench_root=Path(os.environ["VSR_BENCH_ROOT"]),
        stream=args.stream,
        stream_idle_s=args.stream_idle,
        stream_first_event_s=args.stream_first_event,
        per_model_concurrency=member_gates(pool),
    )
    for name, limit in config.per_model_concurrency:
        print(f"[INFO] {name} held at {limit} in flight (declared in the pool)")
    guard_output(out, config)
    stats = asyncio.run(
        runner.run(
            tasks,
            config,
            out,
            on_record=_progress(),
            already_retired=runner.retired_arms(out),
        )
    )
    return report_run(stats, out)


def cmd_repeat(args: argparse.Namespace) -> int:
    """Re-ask a subset, so the matrix's own repeatability is a measured number."""
    items = load_items(args)
    pool = members(args)
    if args.questions and args.questions < len(items):
        # A deterministic subset, so a repeat pass can itself be resumed and
        # extended without changing which questions it covers.
        items = sorted(items, key=lambda i: dataset.fold_of(i.question_id, "repeat"))
        items = items[: args.questions]
    out = args.out or args.out_dir / f"repeat-{args.fold or 'all'}.jsonl"
    skip = runner.completed_cells(out) if args.resume else set()
    tasks = runner.plan(
        runner.repeat_tasks(items, arms(args, pool)),
        seed=args.shuffle_seed + 1,
        skip=skip,
    )
    print(f"[INFO] {len(tasks)} repeat calls over {len(items)} questions -> {out}")
    guard_spend(arms(args, pool), len(items), args.max_tokens, args.max_spend_usd)
    config = runner.RunConfig(
        url=env("VSR_URL"),
        max_tokens=args.max_tokens,
        temperature=args.temperature,
        concurrency=args.concurrency,
        max_attempts=args.max_attempts,
        timeout_s=args.timeout,
        shuffle_seed=args.shuffle_seed,
        api_key=os.environ.get("STRATOCLAVE_API_KEY") or None,
        bench_root=Path(os.environ["VSR_BENCH_ROOT"]),
        stream=args.stream,
        stream_idle_s=args.stream_idle,
        stream_first_event_s=args.stream_first_event,
        per_model_concurrency=member_gates(pool),
    )
    guard_output(out, config)
    stats = asyncio.run(
        runner.run(
            tasks,
            config,
            out,
            on_record=_progress(),
            already_retired=runner.retired_arms(out),
        )
    )
    return report_run(stats, out)


def cmd_mixed(args: argparse.Namespace) -> int:
    """Collect the pinned matrix and a routed arm in one interleaved pass.

    This is the right way to collect a routed arm, and running it separately is
    the wrong one. The comparison the benchmark exists to make is routed against
    pinned; upstream providers drift over hours, aliases can be updated
    underneath us, and a balance drains as a run proceeds. Collecting the two
    arms in different time windows puts every one of those effects squarely into
    that comparison. Shuffled into one task list, they land on both sides alike.
    """
    items = load_items(args)
    pool = members(args)
    out = args.out or args.out_dir / f"mixed-{args.fold or 'all'}.jsonl"
    skip = runner.completed_cells(out) if args.resume else set()

    arm_list = arms(args, pool)
    tasks = runner.pinned_tasks(items, arm_list)
    tasks += runner.routed_tasks(items, args.entrypoint, f"routed:{args.arm}")
    tasks = runner.plan(tasks, seed=args.shuffle_seed, skip=skip)
    if skip:
        print(f"[INFO] resuming: {len(skip)} cells already recorded")
    print(
        f"[INFO] {len(tasks)} calls ({len(arm_list)} pinned arms + routed:{args.arm}) "
        f"at concurrency {args.concurrency} -> {out}"
    )
    guard_spend(arm_list, len(items), args.max_tokens, args.max_spend_usd)

    config = runner.RunConfig(
        url=env("VSR_URL"),
        max_tokens=args.max_tokens,
        temperature=args.temperature,
        concurrency=args.concurrency,
        max_attempts=args.max_attempts,
        timeout_s=args.timeout,
        shuffle_seed=args.shuffle_seed,
        api_key=os.environ.get("STRATOCLAVE_API_KEY") or None,
        bench_root=Path(os.environ["VSR_BENCH_ROOT"]),
        stream=args.stream,
        stream_idle_s=args.stream_idle,
        stream_first_event_s=args.stream_first_event,
        per_model_concurrency=member_gates(pool),
    )
    for name, limit in config.per_model_concurrency:
        print(f"[INFO] {name} held at {limit} in flight (declared in the pool)")
    print(
        "[INFO] the routed arm's own share is not gated: its member is chosen after "
        "the request is sent, so check the selected-model distribution before "
        "reading its latency"
    )
    guard_output(out, config)
    stats = asyncio.run(
        runner.run(
            tasks,
            config,
            out,
            on_record=_progress(),
            already_retired=runner.retired_arms(out),
        )
    )
    return report_run(stats, out)


def cmd_routed(args: argparse.Namespace) -> int:
    items = load_items(args)
    out = args.out or args.out_dir / f"routed-{args.arm}-{args.fold or 'all'}.jsonl"
    skip = runner.completed_cells(out) if args.resume else set()
    tasks = runner.plan(
        runner.routed_tasks(items, args.entrypoint, f"routed:{args.arm}"),
        seed=args.shuffle_seed,
        skip=skip,
    )
    print(f"[INFO] {len(tasks)} routed calls -> {out}")
    # No per-member gate is possible here: the member is chosen after the request
    # is sent. If the selector concentrates on the self-hosted member, that
    # member's queue will appear in this arm's latency, so the run-wide
    # concurrency has to be modest and the realised distribution checked after.
    print("[INFO] per-member gates do not apply to a routed arm; check the "
          "selected-model distribution before reading its latency")
    config = runner.RunConfig(
        url=env("VSR_URL"),
        max_tokens=args.max_tokens,
        temperature=args.temperature,
        concurrency=args.concurrency,
        max_attempts=args.max_attempts,
        timeout_s=args.timeout,
        shuffle_seed=args.shuffle_seed,
        api_key=os.environ.get("STRATOCLAVE_API_KEY") or None,
        bench_root=Path(os.environ["VSR_BENCH_ROOT"]),
        stream=args.stream,
        stream_idle_s=args.stream_idle,
        stream_first_event_s=args.stream_first_event,
    )
    guard_output(out, config)
    stats = asyncio.run(
        runner.run(
            tasks,
            config,
            out,
            on_record=_progress(),
            already_retired=runner.retired_arms(out),
        )
    )
    return report_run(stats, out)


def guard_spend(
    arm_list: list[catalog.Arm], questions: int, max_tokens: int, limit: float | None
) -> None:
    """Show what the completion budget could cost, and stop if it is too much.

    Printed on every collecting run, because the cap is not the neutral setting it
    looks like: a reasoning arm can expand to fill whatever it is given, so raising
    the cap raises the ceiling on the bill by the same factor. `--max-spend-usd` turns
    that ceiling into a refusal instead of a surprise.
    """
    worst = catalog.worst_case_usd(arm_list, questions, max_tokens)
    print(
        f"[INFO] ceiling if every arm spends the whole {max_tokens}-token budget: "
        f"${worst['total']:.2f} ({questions} questions x {len(arm_list)} arms). "
        "Arms that stop early pay far less; this is the bound, not an estimate."
    )
    if limit is not None and worst["total"] > limit:
        dearest = sorted(
            ((v, k) for k, v in worst.items() if k != "total"), reverse=True
        )[:3]
        raise SystemExit(
            f"[FAIL] the ceiling ${worst['total']:.2f} exceeds --max-spend-usd "
            f"{limit:.2f}. Dearest arms: "
            + ", ".join(f"{name} ${cost:.2f}" for cost, name in dearest)
            + ". Lower --max-tokens, cut questions or arms, or raise the limit "
            "deliberately."
        )


def guard_output(out: Path, config: runner.RunConfig) -> None:
    """Refuse to append a run to a file collected under different settings."""
    conflict = runner.settings_conflict(out, config)
    if conflict:
        raise SystemExit(f"[FAIL] {conflict}")
    drift = runner.censoring_drift(out, config)
    if drift:
        print(f"[WARNING] {drift}")


def report_run(stats: runner.RunStats, out: Path) -> int:
    """Print what the run produced, then anything that makes it uncomparable.

    The judgement of what counts as uncomparable lives in `harness.quality`, because
    the analysis has to apply the same policy and must not import a CLI to find it.
    """
    print(
        f"\n[OK] ok={stats.ok} failed={stats.failed} unparsed={stats.unparsed}"
        + (f" skipped={stats.skipped}" if stats.skipped else "")
    )
    for finding in quality.review(stats):
        print(f"\n[WARNING] {finding.headline}")
        for name, detail in finding.rows:
            print(f"    {name:<34}{detail}")

    # Nothing attempted is not a failure: a completed matrix re-run with --resume has
    # every cell already recorded, and a wrapper that reads the exit code should not
    # be told that succeeded run failed. The warnings above deliberately do not change
    # the code either — the Job retries on a non-zero exit, and retrying a run whose
    # budget was too small would just spend the same money again.
    if stats.ok:
        return 0
    return 1 if stats.failed else 0


def _progress():
    state = {"n": 0}

    def report(record) -> None:
        state["n"] += 1
        if state["n"] % 25 == 0 or record.error:
            marker = "!" if record.error else "."
            sys.stdout.write(marker)
            sys.stdout.flush()

    return report


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def common(target: argparse.ArgumentParser) -> None:
        target.add_argument("--dataset", default="mmlu")
        target.add_argument("--categories", nargs="+", default=None)
        target.add_argument("--samples", type=int, default=None, help="questions per category before splitting")
        target.add_argument("--fold", choices=[dataset.CALIBRATION, dataset.VALIDATION, dataset.TEST], default=None)
        target.add_argument("--seed", type=int, default=42)
        target.add_argument("--salt", default=dataset.DEFAULT_SALT)
        target.add_argument("--pool", type=Path, default=None)
        target.add_argument(
            "--only",
            nargs="+",
            default=None,
            help="restrict the run to these pool members (by alias). A pilot that "
            "measures one axis should not pay for the members it does not use",
        )
        target.add_argument(
            "--out-dir",
            type=Path,
            default=DEFAULT_RESULTS,
            help="directory for the default output filenames",
        )
        target.add_argument(
            "--out", type=Path, default=None, help="exact output path, overriding --out-dir"
        )

    def execution(target: argparse.ArgumentParser) -> None:
        target.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
        target.add_argument(
            "--temperature",
            type=float,
            default=None,
            help="omitted by default; no value in this pool is accepted by every member",
        )
        target.add_argument("--concurrency", type=int, default=DEFAULT_CONCURRENCY)
        target.add_argument(
            "--no-stream",
            dest="stream",
            action="store_false",
            help="send on the non-streaming path, as v1 did. The gateway caps a "
            "non-streaming read at 50 seconds, so the high-effort arms are "
            "unmeasurable there; only use this to reproduce a v1 number",
        )
        target.set_defaults(stream=True)
        target.add_argument("--max-attempts", type=int, default=3)
        target.add_argument(
            "--timeout",
            type=float,
            default=300.0,
            help="total deadline, used on the non-streaming path only",
        )
        target.add_argument(
            "--stream-first-event",
            type=float,
            default=600.0,
            help="how long a stream may say nothing at all before it counts as dead. "
            "Far looser than --stream-idle on purpose: a provider that buffers its "
            "thinking sends nothing while doing the work being measured, and one probe "
            "arm exceeded ten minutes",
        )
        target.add_argument(
            "--stream-idle",
            type=float,
            default=90.0,
            help="how long a stream may go silent before it counts as dead. Replaces "
            "the total deadline while streaming, because a high-effort arm's total "
            "duration is a measurement and not a fault",
        )
        target.add_argument(
            "--max-spend-usd",
            type=float,
            default=None,
            help="refuse to start if the completion budget's worst case exceeds this. "
            "The ceiling is always printed; this makes it a stop rather than a surprise",
        )
        target.add_argument("--shuffle-seed", type=int, default=7)
        target.add_argument("--resume", action="store_true")

    p_plan = sub.add_parser("plan", help="shape and cost of a run, without spending")
    common(p_plan)
    p_plan.add_argument("--thin-threshold", type=int, default=40)
    p_plan.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    p_plan.set_defaults(func=cmd_plan)

    p_classify = sub.add_parser("classify", help="decisions only; no model is called")
    common(p_classify)
    p_classify.add_argument("--concurrency", type=int, default=8)
    p_classify.set_defaults(func=cmd_classify)

    p_matrix = sub.add_parser("matrix", help="every member answers every question")
    common(p_matrix)
    execution(p_matrix)
    p_matrix.set_defaults(func=cmd_matrix)

    p_routed = sub.add_parser("routed", help="the router chooses (separate pass)")
    common(p_routed)
    execution(p_routed)
    p_routed.add_argument("--arm", required=True, help="name recorded for this arm")
    p_routed.add_argument("--entrypoint", default="vllm-sr/mom-bench")
    p_routed.set_defaults(func=cmd_routed)

    p_repeat = sub.add_parser(
        "repeat", help="re-ask a subset to measure the matrix's repeatability"
    )
    common(p_repeat)
    execution(p_repeat)
    p_repeat.add_argument(
        "--questions", type=int, default=100, help="how many questions to re-ask"
    )
    p_repeat.set_defaults(func=cmd_repeat)

    p_mixed = sub.add_parser(
        "mixed", help="the pinned matrix and a routed arm, interleaved in one pass"
    )
    common(p_mixed)
    execution(p_mixed)
    p_mixed.add_argument("--arm", required=True, help="name recorded for the routed arm")
    p_mixed.add_argument("--entrypoint", default="vllm-sr/mom-bench")
    p_mixed.set_defaults(func=cmd_mixed)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
