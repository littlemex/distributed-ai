#!/usr/bin/env python3
"""Turn collected calls into the arms, the frontier and the audit.

    ./analyze.py --matrix results/*/matrix-*.jsonl --fold test \
                 --fit-fold calibration [--routed results/routed-*.jsonl] \
                 [--decisions results/decisions-all.jsonl] [--summary out.json]

Nothing here calls a model. Every arm except a routed one is a reading of the
correctness matrix, so the report can be rebuilt, re-sliced and corrected without
spending anything.

The audit runs first and on purpose. A per-member unparsed rate that differs
across the pool means part of the accuracy column is answer formatting rather
than knowledge, and no amount of resampling fixes that — so it is printed before
any comparison, not in an appendix.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Sequence

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from harness import catalog, policies, score, stats  # noqa: E402

DEFAULT_POOL = HERE.parent / "vsr" / "pool.yaml"
# MMLU-Pro offers up to ten options, which is what sets the guessing floor the
# existential bound has to be read against.
MMLU_PRO_OPTIONS = 10


def load_routed(
    paths: Sequence[Path],
    matrix: policies.Matrix,
    name: str,
    qids: Sequence[str],
) -> tuple[policies.ArmResult, dict[str, int]]:
    """Build a routed arm on exactly the questions the pinned arms were scored on.

    Restricted to `qids` on purpose. The pinned arms are scored on the questions
    every member answered; scoring a routed arm on whatever it happened to answer
    would give it a different, easier population — failures fall on the long, hard
    questions — and the difference would be read as routing. So the routed arm gets
    the same denominator, and questions it is missing are reported rather than
    quietly dropped.

    A failure counts as wrong. The router is deliberately fail-closed, so a request
    that produced no answer is an outcome of this arm, not a gap in the data.
    """
    wanted = set(qids)
    rows: dict[str, dict] = {}
    for path in paths:
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if not str(row.get("arm", "")).startswith("routed:"):
                continue
            if row["question_id"] in wanted:
                rows[row["question_id"]] = row

    audit = {"scored": 0, "missing": 0, "failed": 0, "unattributed": 0}
    outcomes = []
    for qid in qids:
        row = rows.get(qid)
        if row is None:
            audit["missing"] += 1
            continue
        audit["scored"] += 1
        if row.get("error"):
            audit["failed"] += 1
            outcomes.append(
                policies.Outcome(
                    question_id=qid,
                    category=matrix.questions[qid].category,
                    member=None,
                    correct=False,
                    cost_usd=0.0,
                    latency_ms=float(row.get("latency_ms") or 0.0),
                )
            )
            continue
        chosen = (row.get("headers") or {}).get("vsr_selected_model")
        member = matrix.members.get(chosen) if chosen else None
        if member is None:
            # Answered, but the router did not say by whom, so the call cannot be
            # priced. Counted and excluded rather than costed at zero, which would
            # make the arm look free.
            audit["unattributed"] += 1
            continue
        outcomes.append(
            policies.Outcome(
                question_id=qid,
                category=matrix.questions[qid].category,
                member=chosen,
                correct=bool(row.get("correct")),
                cost_usd=member.cost_usd(
                    int(row.get("prompt_tokens") or 0),
                    int(row.get("completion_tokens") or 0),
                ),
                latency_ms=float(row.get("latency_ms") or 0.0),
            )
        )
    return policies.ArmResult(name=name, outcomes=tuple(outcomes)), audit


def classifier_labels(path: Path) -> dict[str, str]:
    """Question id -> the domain the classifier matched, where it matched one."""
    labels: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        domains = row.get("matched_domains") or []
        if domains and not row.get("error"):
            labels[row["question_id"]] = domains[0]
    return labels


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--matrix", nargs="+", type=Path, required=True)
    parser.add_argument("--routed", nargs="*", type=Path, default=[])
    parser.add_argument("--decisions", type=Path, default=None)
    parser.add_argument(
        "--repeat",
        nargs="*",
        type=Path,
        default=[],
        help="repeat-pass files, for the per-cell flip rate",
    )
    parser.add_argument("--pool", type=Path, default=DEFAULT_POOL)
    parser.add_argument("--fold", default="test", help="fold the arms are scored on")
    parser.add_argument("--fit-fold", default="calibration", help="fold the policy is fitted on")
    parser.add_argument("--alpha", type=float, default=0.05)
    parser.add_argument("--bootstrap-rounds", type=int, default=2000)
    parser.add_argument("--summary", type=Path, default=None, help="write quality scores here")
    parser.add_argument(
        "--margin",
        type=float,
        default=policies.DEFAULT_MAX_ACCURACY_GIVEUP,
        help=(
            "non-inferiority margin, and the accuracy the assignment rule may trade "
            "for a lower price. One number for both, so the rule and its verdict "
            "speak about the same quantity"
        ),
    )
    parser.add_argument(
        "--lambda-grid",
        nargs="+",
        type=float,
        default=list(policies.DEFAULT_LAMBDA_GRID),
        help="accuracy-per-dollar exchange rates to test routability at",
    )
    parser.add_argument(
        "--margin-sweep",
        nargs="+",
        type=float,
        default=[0.0, 0.01, 0.02, 0.05],
        help="margins to re-derive the assignment and the verdict at",
    )
    parser.add_argument(
        "--unparsed-budget",
        type=float,
        default=0.03,
        help="per-member unparsed rate above which the comparison is called contaminated",
    )
    args = parser.parse_args(argv)

    defaults = os.environ.get("STRATOCLAVE_DEFAULTS")
    if not defaults:
        raise SystemExit("[FAIL] STRATOCLAVE_DEFAULTS is required")
    members = catalog.load_pool(args.pool, Path(defaults))
    matrix = policies.load_matrix(args.matrix, members)

    fit_ids = matrix.complete_ids(args.fit_fold)
    test_ids = matrix.complete_ids(args.fold)
    print(f"[INFO] {len(matrix.members)} members")
    print(f"[INFO] {args.fit_fold}: {len(fit_ids)} complete questions")
    print(f"[INFO] {args.fold}: {len(test_ids)} complete questions")
    for fold in {args.fit_fold, args.fold}:
        dropped = matrix.incomplete_ids(fold)
        if dropped:
            print(
                f"[WARNING] {len(dropped)} {fold} questions dropped: not every member "
                "answered them, and an arm may only be scored where every arm could be"
            )
    if not test_ids:
        raise SystemExit(f"[FAIL] no complete questions in fold {args.fold}")

    audit = policies.deletion_audit(matrix, args.fold)
    if audit["dropped"]:
        kept_acc = audit["kept_mean_member_accuracy"]
        drop_acc = audit["dropped_mean_member_accuracy"]
        print(
            f"[INFO] dropped {audit['dropped']} of {audit['dropped'] + audit['kept']}: "
            f"mean member accuracy {drop_acc:.3f} on the dropped vs {kept_acc:.3f} on "
            "the kept"
            if drop_acc is not None and kept_acc is not None
            else f"[INFO] dropped {audit['dropped']} questions"
        )
        if drop_acc is not None and kept_acc is not None and drop_acc < kept_acc - 0.05:
            print(
                "[WARNING] the dropped questions were harder than the kept ones, so "
                "every arm's accuracy here is optimistic and the existential bound most "
                "of all"
            )

    # ---- audit first ------------------------------------------------------- #
    print("\n== how the calls were answered ==")
    paths_seen = policies.response_path_counts(args.matrix)
    for where, count in sorted(paths_seen.items(), key=lambda kv: -kv[1]):
        print(f"    {where:<30}{count:>7}")
    not_upstream = {k: v for k, v in paths_seen.items() if k != "upstream"}
    if not_upstream:
        raise SystemExit(
            "[FAIL] some calls were not answered upstream "
            f"({not_upstream}). The router's semantic cache is enabled, and a cached "
            "answer has the cost and latency of nothing; scoring it would flatter "
            "whichever arm asked second. Disable the cache or drop those calls."
        )

    spend = policies.spend_report(args.matrix, members)
    print(
        f"\n[INFO] these inputs record {spend['calls']:,} calls, "
        f"{spend['tokens']:,} tokens ({spend['gateway_charged_tokens']:,} charged to the "
        f"gateway, ${spend['gateway_cost_usd']:.2f}); {spend['retried_calls']} needed more "
        "than one attempt, whose extra tokens are billed but not recorded here"
    )

    served = policies.served_models(args.matrix, members)
    drifted = {k: v for k, v in served.items() if len(v) > 1}
    if drifted:
        print("\n[WARNING] a member was served by more than one upstream model id:")
        for name, ids in drifted.items():
            print(f"    {name:<30}{ids}")
        print(
            "    an alias was repointed during collection, so the folds are not "
            "measuring the same model"
        )

    print("\n== answer-format audit ==")
    rates = policies.parse_failure_rates(matrix, test_ids)
    contaminated = []
    for name, rate in sorted(rates.items(), key=lambda kv: -kv[1]):
        flag = ""
        if rate > args.unparsed_budget:
            flag = "  <- above budget"
            contaminated.append(name)
        print(f"    {name:<30} unparsed {rate:6.2%}{flag}")
    if contaminated:
        print(
            f"[WARNING] {len(contaminated)} members exceed the {args.unparsed_budget:.0%} "
            "unparsed budget; part of their accuracy is formatting, not knowledge"
        )

    if args.repeat:
        existing = [p for p in args.repeat if p.exists()]
        rates = policies.flip_rates(existing, matrix) if existing else {}
        if rates:
            print("\n== repeatability ==")
            worst = 0.0
            for name, bucket in sorted(rates.items(), key=lambda kv: -kv[1]["rate"]):
                worst = max(worst, bucket["rate"])
                print(
                    f"    {name:<30}{bucket['flipped']:>4}/{bucket['compared']:<5}"
                    f" flipped on a second ask  {bucket['rate']:6.2%}"
                )
            print(
                f"    a per-cell flip rate near {worst:.1%} inflates the existential "
                "bound most, since it\n    gains from every independent flip"
            )

    # ---- single members and the frontier they already reach ---------------- #
    singles = {name: policies.pinned(matrix, name, test_ids) for name in matrix.members}
    points = [
        policies.Point(label=name, cost_per_question=arm.cost_per_question, accuracy=arm.accuracy)
        for name, arm in singles.items()
    ]
    hull = policies.mixture_frontier(points)

    print("\n== single members on the test fold ==")
    print(f"    {'member':<30}{'accuracy':>10}{'$/question':>13}{'on hull':>9}")
    hull_labels = {p.label for p in hull}
    for point in sorted(points, key=lambda p: -p.accuracy):
        mark = "yes" if point.label in hull_labels else ""
        print(f"    {point.label:<30}{point.accuracy:>10.4f}{point.cost_per_question:>13.6f}{mark:>9}")
    print(
        "    the hull is what mixing two members reaches by coin flip, so it is the "
        "line a router has to clear"
    )

    # ---- fitted policies, on the fitting fold only ------------------------- #
    domain_choices = policies.fit_domain_assignment(
        matrix, args.fit_fold, alpha=args.alpha, max_accuracy_giveup=args.margin
    )
    global_choice = policies.fit_global_choice(
        matrix, args.fit_fold, alpha=args.alpha, max_accuracy_giveup=args.margin
    )
    calib_best = policies.best_single_by_accuracy(matrix, args.fit_fold)

    print(f"\n== assignment fitted on {args.fit_fold} ==")
    print(f"    {'domain':<22}{'chosen':<30}{'best acc':>9}{'chosen':>9}{'tied':>6}{'n':>5}")
    for domain, choice in domain_choices.items():
        print(
            f"    {domain:<22}{choice.chosen:<30}{choice.best_accuracy:>9.3f}"
            f"{choice.chosen_accuracy:>9.3f}{len(choice.tied_with):>6}{choice.n_questions:>5}"
        )
    print(f"    global (no domain split): {global_choice.chosen} "
          f"(tied with {len(global_choice.tied_with)} of {len(matrix.members)})")
    distinct = {choice.chosen for choice in domain_choices.values()}
    if len(distinct) == 1:
        print(
            "[NOTE] the domain split chose one member everywhere, so on this fold it is "
            "the same policy as the global rule and buys nothing by construction"
        )

    # ---- arms -------------------------------------------------------------- #
    arms: list[policies.ArmResult] = []
    arms.append(policies.pinned(matrix, calib_best, test_ids))
    arms[-1] = policies.ArmResult(f"best_single_by_{args.fit_fold}:{calib_best}", arms[-1].outcomes)

    # Chosen by its cost on the fitting fold. Picking the cheapest by its cost on
    # the fold it is then scored on would hold the baseline to a looser standard
    # than the router, which is frozen before the test fold is opened.
    fit_cost = {
        name: policies.pinned(matrix, name, fit_ids).cost_per_question
        for name in matrix.members
    }
    cheapest = min(matrix.members, key=lambda n: fit_cost[n])
    arms.append(policies.ArmResult(f"cheapest_by_{args.fit_fold}:{cheapest}", singles[cheapest].outcomes))

    arms.append(
        policies.ArmResult(
            f"global_static:{global_choice.chosen}",
            singles[global_choice.chosen].outcomes,
        )
    )

    def by_true_domain(qid: str) -> str:
        category = matrix.questions[qid].category
        choice = domain_choices.get(category)
        return choice.chosen if choice else global_choice.chosen

    arms.append(
        policies.by_assignment(matrix, test_ids, by_true_domain, "domain_static:true_label")
    )

    if args.decisions and args.decisions.exists():
        labels = classifier_labels(args.decisions)
        agreed = sum(1 for q in test_ids if labels.get(q) == matrix.questions[q].category)
        covered = sum(1 for q in test_ids if q in labels)
        print(
            f"\n[INFO] classifier labels available for {covered}/{len(test_ids)} test "
            f"questions; agrees with the dataset category on {agreed}/{covered}"
            if covered
            else "\n[WARNING] no usable classifier labels"
        )

        def by_classifier_domain(qid: str) -> str:
            label = labels.get(qid)
            choice = domain_choices.get(label) if label else None
            return choice.chosen if choice else global_choice.chosen

        arms.append(
            policies.by_assignment(
                matrix, test_ids, by_classifier_domain, "domain_static:classifier_label"
            )
        )

    arms.append(policies.random_uniform(matrix, test_ids))
    arms.append(policies.oracle_answer(matrix, test_ids, cost_aware=False))
    arms.append(policies.oracle_answer(matrix, test_ids, cost_aware=True))

    routed_paths = [p for p in list(args.routed) + list(args.matrix) if p.exists()]
    if routed_paths:
        routed_arm, routed_audit = load_routed(
            routed_paths, matrix, "routed:multi_factor", test_ids
        )
        if routed_arm.outcomes:
            arms.append(routed_arm)
            print(
                f"\n[INFO] routed arm scored on {routed_audit['scored']} of "
                f"{len(test_ids)} test questions "
                f"({routed_audit['failed']} failed, counted wrong; "
                f"{routed_audit['unattributed']} answered but unattributable, excluded)"
            )
            if routed_audit["missing"]:
                print(
                    f"[WARNING] {routed_audit['missing']} test questions have no routed "
                    "call; the routed arm is scored on a subset of the pinned population"
                )

    # ---- report ------------------------------------------------------------ #
    baseline = arms[0]
    print(f"\n== arms on the {args.fold} fold, against {baseline.name} ==")
    print(f"    {'arm':<40}{'accuracy':>10}{'$/question':>12}{'vs base acc':>28}")
    for arm in arms:
        delta = (
            policies.paired_accuracy_delta(arm, baseline, rounds=args.bootstrap_rounds)
            if arm is not baseline
            else None
        )
        shown = str(delta) if delta else "(baseline)"
        print(
            f"    {arm.name:<40}{arm.accuracy:>10.4f}{arm.cost_per_question:>12.6f}{shown:>28}"
        )

    print(
        f"\n== is it no less accurate, for less money? (margin {args.margin:.3f}) =="
    )
    print(
        "    a two-sided interval containing zero would only mean the data cannot "
        "resolve the\n    difference, so the claim is tested one-sided against the "
        "margin the assignment rule\n    was allowed to trade away."
    )
    comparisons = {}
    for arm in arms:
        if arm is baseline:
            continue
        ni = policies.accuracy_non_inferiority(
            arm, baseline, margin=args.margin, rounds=args.bootstrap_rounds
        )
        cost = policies.paired_cost_delta(arm, baseline, rounds=args.bootstrap_rounds)
        latency = policies.paired_latency_delta(arm, baseline, rounds=args.bootstrap_rounds)
        comparisons[arm.name] = (ni, cost, latency)
        share = (
            f"{cost.point / baseline.cost_per_question:+.1%}"
            if baseline.cost_per_question
            else "n/a"
        )
        status = "PASS" if ni.passes else "fail"
        if ni.superior:
            status = "PASS+"
        print(
            f"    {arm.name:<42}{status:<6}Δacc {ni.delta:+.4f} (lb {ni.lower_bound:+.4f})"
            f"  cost {share:>8}  latency {latency.point:+8.0f} ms"
        )

    # Every arm above is tested against the same baseline, so the family needs a
    # correction: at a dozen comparisons, one crosses a 5% threshold by arithmetic
    # alone. Holm is applied to the two-sided accuracy differences, which is where a
    # spurious "wins" would come from.
    if len(comparisons) > 1:
        p_values = {
            name: policies.paired_accuracy_p_value(
                next(a for a in arms if a.name == name),
                baseline,
                rounds=args.bootstrap_rounds,
            )
            for name in comparisons
        }
        survives = stats.holm(p_values, alpha=args.alpha)
        flagged = [name for name, kept in survives.items() if kept]
        print(
            f"    after Holm across {len(comparisons)} comparisons, "
            f"{len(flagged)} accuracy difference(s) remain distinguishable from zero: "
            + (", ".join(flagged) if flagged else "none")
        )

    print("\n== against the mixture frontier ==")
    print(
        "    the hull is refitted inside every resample, so the interval carries its "
        "own\n    uncertainty and not just the arm's."
    )
    for arm in arms:
        # A single member is one of the points the hull was built from, so its gap
        # is zero or negative by construction and says nothing. Only arms that
        # combine members can clear it.
        if len(arm.selection_counts()) == 1 and not arm.name.startswith("routed:"):
            continue
        reachable = policies.frontier_accuracy_at(hull, arm.cost_per_question)
        if reachable is None:
            print(
                f"    {arm.name:<42}cheaper than every single member, so the frontier "
                "says nothing here"
            )
            continue
        interval = policies.frontier_gap_interval(
            matrix, arm, test_ids, rounds=max(200, args.bootstrap_rounds // 4)
        )
        note = (
            "above the hull" if interval.low > 0
            else "not shown to clear the hull"
        )
        print(f"    {arm.name:<42}{interval}   {note}")

    oracle = next(a for a in arms if a.name == "oracle:any_correct")
    guessing = score.guessing_union_accuracy(len(matrix.members), MMLU_PRO_OPTIONS)
    print(
        f"\n[NOTE] the existential bound is {oracle.accuracy:.4f}. Ten independent guessers "
        f"over {MMLU_PRO_OPTIONS} options reach {guessing:.4f} between them while knowing "
        "nothing, so it is a bound on the pool's complementarity, not a target."
    )
    for arm in arms:
        coverage = policies.gap_coverage(arm.accuracy, baseline.accuracy, oracle.accuracy)
        if coverage is not None and arm is not baseline and not arm.name.startswith("oracle:"):
            print(f"    {arm.name:<40}gap coverage {coverage:+.1%}")

    print("\n== by category ==")
    print("    an average can hide a domain where the routing is actively wrong")
    categories = sorted({matrix.questions[q].category for q in test_ids})
    interesting = [
        a
        for a in arms
        if a.name.startswith(("domain_static", "routed", "global_static"))
        or a is baseline
    ]
    header = "    {:<22}".format("category") + "".join(
        f"{a.name.split(':')[0][:14]:>16}" for a in interesting
    )
    print(header)
    for category in categories:
        cells = []
        for arm in interesting:
            subset = [o for o in arm.outcomes if o.category == category]
            cells.append(
                f"{sum(o.score for o in subset) / len(subset):>16.3f}" if subset else f"{'-':>16}"
            )
        print(f"    {category:<22}" + "".join(cells))
    for arm in interesting:
        if arm is baseline:
            continue
        counts = arm.selection_counts()
        if len(counts) > 1:
            print(f"    {arm.name} spread over {len(counts)} members")

    print("\n== could domain routing have helped at all? ==")
    print(
        "    the ceiling for any per-domain policy, against the same ceiling with the\n"
        "    labels shuffled. Measured on utility = accuracy - lambda x cost, because a\n"
        "    feature that predicts difficulty rather than which arm wins moves an\n"
        "    accuracy ceiling not at all while being exactly what cost-aware routing\n"
        "    lives on. lambda is the dollars per question one accuracy point is worth,\n"
        "    inverted: lambda=5 values a point at $0.002, lambda=100 at $0.0001."
    )
    print(f"    {'lambda':>8}{'best arm':>11}{'ceiling':>10}{'shuffled':>10}{'p':>8}   verdict")
    for lam in args.lambda_grid:
        diag = policies.routability(
            matrix, args.fold, lambda_=lam, rounds=max(600, args.bootstrap_rounds // 3)
        )
        print(
            f"    {lam:>8.0f}{diag.best_single_utility:>11.4f}{diag.ceiling:>10.4f}"
            f"{diag.null_ceiling_mean:>10.4f}{diag.p_value:>8.3f}   {diag.verdict()}"
        )

    print("\n== how many members does the pool need? ==")
    print("    existential ceiling as members are added greedily")
    previous = 0.0
    for index, (name, value) in enumerate(policies.arm_set_value(matrix, test_ids), 1):
        delta = value - previous if index > 1 else 0.0
        previous = value
        suffix = f"  (+{delta:.4f})" if index > 1 else ""
        print(f"    top-{index}: {value:.4f}{suffix}  added {name}")

    print("\n== where routing could pay: disagreement among the strongest ==")
    for a, b, phi, disagree in policies.error_overlap(matrix, test_ids):
        print(
            f"    {a.split('/')[-1]:<24}{b.split('/')[-1]:<24}phi {phi:+.3f}  "
            f"exactly one correct on {disagree} of {len(test_ids)}"
        )

    print("\n== margin sensitivity ==")
    print(
        "    the margin is the one free number in the rule, so the conclusion has to "
        "be shown\n    against several. A verdict that only holds at one margin is a "
        "product of the rule."
    )
    for margin in args.margin_sweep:
        choices = policies.fit_domain_assignment(
            matrix, args.fit_fold, alpha=args.alpha, max_accuracy_giveup=margin
        )
        arm = policies.by_assignment(
            matrix,
            test_ids,
            lambda qid, c=choices: (
                c[matrix.questions[qid].category].chosen
                if matrix.questions[qid].category in c
                else global_choice.chosen
            ),
            f"domain_static@{margin}",
        )
        ni = policies.accuracy_non_inferiority(
            arm, baseline, margin=margin, rounds=args.bootstrap_rounds
        )
        cost = policies.paired_cost_delta(arm, baseline, rounds=args.bootstrap_rounds)
        share = (
            f"{cost.point / baseline.cost_per_question:+.1%}"
            if baseline.cost_per_question
            else "n/a"
        )
        distinct = len({c.chosen for c in choices.values()})
        status = "PASS+" if ni.superior else ("PASS" if ni.passes else "fail")
        print(
            f"    margin {margin:.3f}  {status:<6}acc {arm.accuracy:.4f} "
            f"(Δ {ni.delta:+.4f}, lb {ni.lower_bound:+.4f})  cost {share:>8}  "
            f"{distinct} distinct members chosen"
        )

    routed_arms = [a for a in arms if a.name.startswith("routed:")]
    for arm in routed_arms:
        print(f"\n== {arm.name} selected ==")
        total = len(arm.outcomes)
        for name, count in sorted(arm.selection_counts().items(), key=lambda kv: -kv[1]):
            print(f"    {name:<30}{count:>6}  {count / total:6.1%}")

    if args.summary:
        # `build_config.py --quality-from` reads this to replace the price prior
        # with measured accuracy. Written from the fitting fold, never from the
        # test fold: seeding the router from the numbers it will be judged on
        # would make the test fold part of the fitting.
        fit_singles = {
            name: policies.pinned(matrix, name, fit_ids).accuracy for name in matrix.members
        }
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        args.summary.write_text(
            json.dumps(
                {
                    "source_fold": args.fit_fold,
                    "n_questions": len(fit_ids),
                    "accuracy_by_model": fit_singles,
                },
                indent=2,
                sort_keys=True,
            )
            + "\n"
        )
        print(f"\n[OK] quality scores from {args.fit_fold} -> {args.summary}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
