#!/usr/bin/env python3
"""Can v2 resolve the difference it is looking for? A screen, run before spending.

    ./power.py --matrix results/calib-01/*.jsonl results/test-01/*.jsonl \
               --repeat results/repeat-01/*.jsonl --fold test --fit-fold calibration

v2's primary estimand is a paired per-question difference between two selections over
arms, `D_q = u(all arms) − u(best single model's arms)`, and its expected size is one to
two utility points. Whether that is resolvable is a property of **discordance** — the
share of questions on which exactly one side is right — and not of either side's
accuracy. This script measures discordance and the paired-difference distribution from
v1's own matrix and reports what sample size they imply.

Two limits, stated because the output is otherwise easy to over-read.

**This can only reject.** v1 measured the model axis and holds no cell for a member at
a non-default effort, so the discordance between a member and its own higher effort
level — the quantity v2 turns on — is not observable here. What is observable is the
discordance between *comparable strong arms*, which is the structure any Δ estimator
inherits. And the surrogate is optimistic in a second way: it takes two fixed arms,
while the real estimand chooses both sides, so the real variance includes a selection
term this does not. A design that fails the screen cannot pass the real calculation; a
design that passes still has to face the pilot.

**The shift is injected, not observed.** Power at a Δ that the data does not contain is
computed by centring the observed paired differences and adding Δ. That keeps the real
dependence structure and the real heavy tail while making the effect size a knob, which
is the point — the question is not "was v1 significant" but "at what n would a Δ of one
point be".
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from harness import catalog, policies  # noqa: E402

DEFAULT_POOL = HERE.parent / "vsr" / "pool.yaml"

# Two-sided 5% and 80% power. Written out rather than imported so the numbers in the
# report can be traced without a stats package.
Z_ALPHA = 1.959963985
Z_POWER = 0.841621234
MDE_FACTOR = Z_ALPHA + Z_POWER

# The differences v2 is trying to see, in utility points.
DEFAULT_TARGETS = (0.01, 0.02)


def utilities(matrix: policies.Matrix, qids: list[str], lam: float) -> dict[str, np.ndarray]:
    """Per arm, its utility on each question: `correct − lambda * cost`."""
    out = {}
    for name, member in matrix.members.items():
        row = []
        for qid in qids:
            cell = matrix.cells[qid][name]
            row.append(float(cell.correct) - lam * cell.cost_usd(member))
        out[name] = np.array(row, dtype=float)
    return out


def correctness(matrix: policies.Matrix, qids: list[str]) -> dict[str, np.ndarray]:
    return {
        name: np.array([matrix.cells[qid][name].correct for qid in qids], dtype=bool)
        for name in matrix.members
    }


def discordance_table(
    correct: dict[str, np.ndarray], names: list[str]
) -> list[tuple[str, str, float, float]]:
    """For each pair, the share of questions where exactly one of them is right.

    This is the denominator of power for a paired binary comparison: questions both
    sides get right or both get wrong contribute nothing to the difference, however
    many of them there are.
    """
    rows = []
    for i, a in enumerate(names):
        for b in names[i + 1 :]:
            only_a = np.sum(correct[a] & ~correct[b])
            only_b = np.sum(~correct[a] & correct[b])
            n = len(correct[a])
            rows.append((a, b, (only_a + only_b) / n, (only_a - only_b) / n))
    return sorted(rows, key=lambda r: -r[2])


def n_for(discordance: float, target: float) -> int:
    """Questions needed to resolve `target` at a paired binary discordance."""
    if target <= 0:
        return 0
    return math.ceil(discordance * (MDE_FACTOR / target) ** 2)


def mde_at(discordance: float, n: int) -> float:
    return MDE_FACTOR * math.sqrt(discordance / n) if n else float("inf")


def bootstrap_power(
    differences: np.ndarray,
    *,
    delta: float,
    n: int,
    sims: int,
    rng: np.random.Generator,
) -> float:
    """Rejection rate for a mean-difference test on `n` questions at a true `delta`.

    Resamples questions with replacement from the centred observed differences, which
    keeps the real spread and the real tail rather than assuming a normal one, and uses
    a studentised statistic so the test is the one the report would actually run.
    """
    centred = differences - differences.mean()
    draws = rng.choice(centred, size=(sims, n), replace=True) + delta
    means = draws.mean(axis=1)
    ses = draws.std(axis=1, ddof=1) / math.sqrt(n)
    with np.errstate(divide="ignore", invalid="ignore"):
        stat = np.abs(means) / ses
    return float(np.mean(np.nan_to_num(stat) > Z_ALPHA))


def per_ask_variance(disagreement_rate: float) -> float:
    """Variance of one ask, from the rate at which two asks disagree.

    The repeat pass measures how often re-asking a cell changes the verdict. For a cell
    answered correctly with probability p on each ask, two independent asks disagree with
    probability `2p(1-p)`, while one ask has variance `p(1-p)`. So the measured
    disagreement is twice the quantity wanted here, and using it directly would double
    the measurement term — enough, on this data, to attribute the entire spread between
    two arms to noise.
    """
    return disagreement_rate / 2.0


def variance_split(
    differences: np.ndarray, *, flip_a: float, flip_b: float
) -> tuple[float, float]:
    """How much of the observed spread is real difference and how much is re-asking."""
    measurement = per_ask_variance(flip_a) + per_ask_variance(flip_b)
    observed = float(differences.var(ddof=1))
    return max(observed - measurement, 0.0), measurement


def at_samples_per_cell(
    differences: np.ndarray, *, flip_a: float, flip_b: float, samples: int
) -> np.ndarray:
    """The same paired differences as they would look with `samples` asks per cell.

    A cell asked once is one Bernoulli draw, and the repeat pass measured the verdict
    changing between 1.7 and 20 percent of the time. That noise is unbiased in the mean,
    so it does not shrink Δ — it widens the interval, and asking each cell more than
    once is the lever that narrows it again.

    The adjustment is on the variance rather than by resampling noise on top of the
    observed data, because the observed data *already contains one draw* of it: adding
    another would count it twice. The observed spread at one ask is the truth's spread
    plus one unit of measurement variance; at k asks it is the truth's plus a k-th.
    Scaling keeps the distribution's shape, which matters because the utility versions
    have a heavy cost tail that a normal approximation would flatter.
    """
    observed_var = float(differences.var(ddof=1))
    if observed_var <= 0 or samples <= 1:
        return differences
    truth_var, measurement = variance_split(
        differences, flip_a=flip_a, flip_b=flip_b
    )
    target_var = truth_var + measurement / samples
    scale = math.sqrt(target_var / observed_var)
    return (differences - differences.mean()) * scale + differences.mean()


def read_arm_cells(
    paths: list[Path], members: list[catalog.Member]
) -> tuple[dict[str, dict[str, dict]], list[str]]:
    """Rows keyed by arm and question, with each cell's cost.

    Deliberately not `policies.load_matrix`, which keys cells by member: four arms of
    one member share a `requested_model`, so that loader sees four answers to the same
    cell and refuses the file. Making it arm-granular is the next real piece of work on
    the analysis side; the pilot needs the numbers before that lands, and reading the
    rows here keeps the shortcut visible instead of quietly widening a loader that the
    rest of the report depends on.

    Returns the cells and the questions every arm answered — an arm may only be scored
    where every arm could have been.
    """
    by_model = {m.name: m for m in members}
    cells: dict[str, dict[str, dict]] = {}
    for path in paths:
        with path.open() as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                arm = row["arm"].split(":", 1)[1] if ":" in row["arm"] else row["arm"]
                member = by_model.get(row["requested_model"])
                if member is None or row.get("error"):
                    continue
                cells.setdefault(arm, {})[row["question_id"]] = {
                    "correct": bool(row.get("correct")),
                    "cost": member.cost_usd(
                        row.get("prompt_tokens") or 0, row.get("completion_tokens") or 0
                    ),
                    "completion_tokens": row.get("completion_tokens") or 0,
                }
    if not cells:
        return cells, []
    complete = set.intersection(*(set(v) for v in cells.values()))
    return cells, sorted(complete)


def arm_flip_rates(paths: list[Path], cells: dict[str, dict[str, dict]]) -> dict[str, float]:
    """Per arm, how often a re-asked question changed its verdict."""
    tally: dict[str, list[int]] = {}
    for path in paths:
        if not path.exists():
            continue
        with path.open() as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                if not str(row.get("arm", "")).startswith("repeat:") or row.get("error"):
                    continue
                arm = row["arm"].split(":", 1)[1]
                first = cells.get(arm, {}).get(row["question_id"])
                if first is None:
                    continue
                bucket = tally.setdefault(arm, [0, 0])
                bucket[0] += 1
                if bool(row.get("correct")) != first["correct"]:
                    bucket[1] += 1
    return {
        arm: (flipped / compared if compared else 0.0)
        for arm, (compared, flipped) in tally.items()
    }


def measured_tokens(
    matrix: policies.Matrix, qids: list[str]
) -> dict[str, tuple[float, float]]:
    """Per member, its mean prompt and completion tokens as actually measured."""
    out = {}
    for name in matrix.members:
        cells = [matrix.cells[qid][name] for qid in qids]
        out[name] = (
            sum(c.prompt_tokens for c in cells) / len(cells),
            sum(c.completion_tokens for c in cells) / len(cells),
        )
    return out


def design_cost_usd(
    arms: list[catalog.Arm],
    measured: dict[str, tuple[float, float]],
    *,
    questions: int,
    samples: int,
) -> float:
    """What a design costs at v1's measured token usage.

    A floor rather than an estimate: every arm is priced at its member's default-effort
    token usage, and the whole point of the effort dial is that a higher level spends
    more. It is still the right order of magnitude to decide with, which the worst-case
    ceiling — every arm filling a 16,384-token budget — is not.
    """
    total = 0.0
    for arm in arms:
        prompt, completion = measured.get(arm.member.name, (0.0, 0.0))
        total += arm.member.cost_usd(int(prompt), int(completion)) * questions * samples
    return total


def report_pilot(
    matrix_paths: list[Path],
    repeat_paths: list[Path],
    members: list[catalog.Member],
    pool: Path,
    targets: list[float],
) -> int:
    """The effort axis measured on itself: what the screen could not observe.

    The screen borrowed between-model discordance as a stand-in. This reads the real
    thing — a member against its own higher levels — which is the quantity the primary
    estimand turns on, and the one that decides whether the design is affordable.
    """
    cells, qids = read_arm_cells(matrix_paths, members)
    if not qids:
        raise SystemExit("[FAIL] no question was answered by every arm")
    arms = catalog.arms(pool, members)
    print(f"[INFO] {len(cells)} arms over {len(qids)} questions answered by all of them")

    flips = arm_flip_rates(repeat_paths, cells)
    if flips:
        print(
            "[INFO] re-ask disagreement measured on "
            f"{len(flips)} arms, {min(flips.values()):.1%} to {max(flips.values()):.1%}"
        )
    else:
        print("[WARNING] no repeat pass yet, so measurement noise is not in these numbers")

    def correct(arm: str) -> np.ndarray:
        return np.array([cells[arm][q]["correct"] for q in qids], dtype=bool)

    def cost(arm: str) -> np.ndarray:
        return np.array([cells[arm][q]["cost"] for q in qids], dtype=float)

    print("\n== within a member: its own effort levels against each other ==")
    print(f"    {'pair':<52}{'discord':>9}{'net':>8}{'cost x':>8}")
    within = []
    for member in members:
        levels = [a.name for a in arms if a.member.name == member.name and a.name in cells]
        for i, a in enumerate(levels):
            for b in levels[i + 1 :]:
                ca, cb = correct(a), correct(b)
                disc = float(np.mean(ca ^ cb))
                net = float(np.mean(ca.astype(float) - cb.astype(float)))
                ratio = cost(a).mean() / cost(b).mean() if cost(b).mean() else float("inf")
                within.append((a, b, disc, net, ratio))
                label = f"{a.replace('sclv/','')} / {b.replace('sclv/','')}"
                print(f"    {label:<52}{disc:>8.1%}{net:>+8.1%}{ratio:>8.1f}")

    print("\n== across members, at the same declared level ==")
    print(f"    {'pair':<52}{'discord':>9}{'net':>8}")
    across = []
    names = [a.name for a in arms if a.name in cells]
    for i, a in enumerate(names):
        for b in names[i + 1 :]:
            if a.split("@")[0] == b.split("@")[0]:
                continue
            suffix_a = a.split("@")[1] if "@" in a else "default"
            suffix_b = b.split("@")[1] if "@" in b else "default"
            if suffix_a != suffix_b:
                continue
            ca, cb = correct(a), correct(b)
            disc = float(np.mean(ca ^ cb))
            across.append(disc)
            label = f"{a.replace('sclv/','')} / {b.replace('sclv/','')}"
            print(f"    {label:<52}{disc:>8.1%}{np.mean(ca.astype(float)-cb.astype(float)):>+8.1%}")

    w = [row[2] for row in within]
    print(
        f"\n    within-member discordance: {min(w):.1%} to {max(w):.1%}, median "
        f"{sorted(w)[len(w)//2]:.1%}"
    )
    if across:
        print(
            f"    across-member at matched level: {min(across):.1%} to {max(across):.1%}, "
            f"median {sorted(across)[len(across)//2]:.1%}"
        )

    print("\n== what that implies for the design ==")
    for label, disc in (
        ("within-member median", sorted(w)[len(w) // 2]),
        ("within-member widest", max(w)),
    ):
        line = f"    {label:<24}d={disc:5.1%}  MDE at n={len(qids)}: {mde_at(disc, len(qids)):6.2%}"
        for target in targets:
            line += f"   n for {target:.0%}: {n_for(disc, target):>7,}"
        print(line)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--matrix", nargs="+", type=Path, required=True)
    parser.add_argument("--repeat", nargs="*", type=Path, default=[])
    parser.add_argument(
        "--pilot",
        action="store_true",
        help="read the matrix at arm granularity and report the effort axis instead of "
        "the model-axis screen",
    )
    parser.add_argument("--pool", type=Path, default=DEFAULT_POOL)
    parser.add_argument(
        "--only",
        nargs="+",
        default=None,
        help="restrict the analysis to these members, matching the run that collected it",
    )
    parser.add_argument("--fold", default="test", help="the fold power is computed on")
    parser.add_argument(
        "--fit-fold",
        default="calibration",
        help="the fold the two compared arms are chosen on, so the surrogate is "
        "cross-fitted the way the real estimand has to be",
    )
    parser.add_argument("--lambdas", nargs="+", type=float, default=[0.0, 20.0])
    parser.add_argument("--targets", nargs="+", type=float, default=list(DEFAULT_TARGETS))
    parser.add_argument("--samples-per-cell", nargs="+", type=int, default=[1, 3])
    parser.add_argument("--sims", type=int, default=4000)
    parser.add_argument("--seed", type=int, default=11)
    parser.add_argument("--top", type=int, default=5, help="how many strong arms to pair")
    parser.add_argument(
        "--designs",
        nargs="+",
        default=["693:1", "693:3", "1200:3", "2700:3"],
        help="questions:asks-per-cell designs to price",
    )
    args = parser.parse_args(argv)

    defaults = os.environ.get("STRATOCLAVE_DEFAULTS")
    if not defaults:
        raise SystemExit("[FAIL] STRATOCLAVE_DEFAULTS is required (for the rate table)")
    members = catalog.only(catalog.load_pool(args.pool, Path(defaults)), args.only)
    if args.pilot:
        return report_pilot(
            args.matrix, list(args.repeat), members, args.pool, args.targets
        )
    matrix = policies.load_matrix(args.matrix, members)
    rng = np.random.default_rng(args.seed)

    fit_ids = matrix.complete_ids(args.fit_fold)
    score_ids = matrix.complete_ids(args.fold)
    if not fit_ids or not score_ids:
        raise SystemExit("[FAIL] both folds need complete questions")
    print(
        f"[INFO] {len(matrix.members)} arms; {len(fit_ids)} complete on {args.fit_fold}, "
        f"{len(score_ids)} on {args.fold}"
    )
    print(
        "[INFO] this is a screen on the model axis: v1 holds no cell for a member at a "
        "non-default effort, so it can reject a design but cannot clear one"
    )

    flips = {}
    existing = [p for p in args.repeat if p.exists()]
    if existing:
        measured = policies.flip_rates(existing, matrix)
        flips = {name: float(bucket["rate"]) for name, bucket in measured.items()}
        if flips:
            worst = max(flips.items(), key=lambda kv: kv[1])
            print(
                f"[INFO] re-ask flip rate measured on {len(flips)} arms, "
                f"worst {worst[0]} at {worst[1]:.1%}"
            )
    else:
        print("[WARNING] no repeat pass given, so measurement noise is left out entirely")

    correct_score = correctness(matrix, score_ids)

    for lam in args.lambdas:
        util_fit = utilities(matrix, fit_ids, lam)
        util_score = utilities(matrix, score_ids, lam)
        ranked = sorted(util_fit, key=lambda name: -util_fit[name].mean())
        strong = ranked[: args.top]
        print(f"\n== lambda = {lam:g} ==")
        print(f"    strongest on {args.fit_fold}: {', '.join(strong)}")

        table = discordance_table(correct_score, strong)
        print(f"\n    discordance among the {len(strong)} strongest arms (accuracy only)")
        print(f"    {'pair':<58}{'discordant':>11}{'net':>8}")
        for a, b, disc, net in table:
            print(f"    {a + ' / ' + b:<58}{disc:>10.1%}{net:>+8.1%}")
        discs = [row[2] for row in table]
        print(
            f"    range {min(discs):.1%} to {max(discs):.1%}, median "
            f"{sorted(discs)[len(discs) // 2]:.1%}"
        )

        print("\n    closed-form screen, paired binary, 5% two-sided at 80% power")
        for label, disc in (
            ("most discordant pair", max(discs)),
            ("median pair", sorted(discs)[len(discs) // 2]),
            ("least discordant pair", min(discs)),
        ):
            line = f"    {label:<24}d={disc:5.1%}  MDE at n={len(score_ids)}: {mde_at(disc, len(score_ids)):6.2%}"
            for target in args.targets:
                line += f"   n for {target:.0%}: {n_for(disc, target):>7,}"
            print(line)

        # The simulation runs on the arms the real estimand would put on either side:
        # the best two on the fitting fold, scored on the other one.
        a, b = ranked[0], ranked[1]
        observed = util_score[a] - util_score[b]
        truth_var, measurement = variance_split(
            observed, flip_a=flips.get(a, 0.0), flip_b=flips.get(b, 0.0)
        )
        print(
            f"\n    simulated on the two strongest ({a} vs {b}), "
            f"observed paired difference {observed.mean():+.4f}, sd {observed.std(ddof=1):.4f}"
        )
        print(
            f"    of that variance {measurement:.4f} is re-asking "
            f"(disagreement {flips.get(a, 0.0):.1%} and {flips.get(b, 0.0):.1%}) and "
            f"{truth_var:.4f} is the arms differing"
            + (
                " — floored at zero, so this data cannot separate the two"
                if truth_var == 0.0
                else ""
            )
        )
        for k in args.samples_per_cell:
            differences = at_samples_per_cell(
                observed,
                flip_a=flips.get(a, 0.0),
                flip_b=flips.get(b, 0.0),
                samples=k,
            )
            for target in args.targets:
                power_now = bootstrap_power(
                    differences,
                    delta=target,
                    n=len(score_ids),
                    sims=args.sims,
                    rng=rng,
                )
                needed = None
                for n in range(len(score_ids), 60_001, 250):
                    if (
                        bootstrap_power(
                            differences, delta=target, n=n, sims=1000, rng=rng
                        )
                        >= 0.8
                    ):
                        needed = n
                        break
                print(
                    f"    {k} sample(s)/cell, Δ={target:.0%}: power at "
                    f"n={len(score_ids)} is {power_now:.0%}; "
                    + (f"80% needs n≈{needed:,}" if needed else "80% needs n>60,000")
                )

    print("\n== what a design that passes would cost ==")
    arms = catalog.arms(args.pool, members)
    measured = measured_tokens(matrix, score_ids)
    for design in args.designs:
        questions, samples = (int(part) for part in design.split(":"))
        cost = design_cost_usd(arms, measured, questions=questions, samples=samples)
        calls = questions * len(arms) * samples
        print(
            f"    {questions:>5} questions x {len(arms)} arms x {samples} asks = "
            f"{calls:>7,} calls   ~${cost:,.0f}"
        )
    print(
        "    priced at v1's measured tokens per member, so it is a floor: a higher "
        "effort level spends more, and by how much is one of the things the pilot is for"
    )

    print(
        "\n[INFO] the pilot the screen cannot replace: the effort axis needs its own "
        "discordance, measured on a member against its own higher levels. To pin a "
        "discordance near 10% to within half its value takes about 140 questions per "
        "pair; to within a quarter, about 550."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
