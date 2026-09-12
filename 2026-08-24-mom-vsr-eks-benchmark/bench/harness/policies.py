"""Arms that are functions of the correctness matrix, and the fitting rule.

Once every member has answered every question, most of the report costs nothing
more to produce: the best single member, the cheapest one, an existential upper
bound, a uniform random choice, and any offline per-domain assignment are all
readings of the same matrix. Only the router deciding for itself needs its own
traffic.

Two things here are claims rather than conveniences, and both are stated as code
so they cannot drift from the prose:

**The assignment rule is mechanical and fixed before the test fold is read.** For
each domain, keep the members that can be *shown* to be no worse than the best one
by more than a fixed margin — a one-sided confidence bound on the paired
difference, not a point estimate — then take the cheapest of those. "Same accuracy,
less money" is the whole thesis, so resolving a certified tie by price is the thesis
applied rather than a thumb on the scale, and because the rule is arithmetic there
is nothing left to tune once the test fold is opened.

The bound, rather than a margin on the observed difference, is what makes the rule
honest at these sample sizes. With a couple of hundred questions per domain the
paired difference carries a standard error of around three points, so "within two
points on this fold" would bound nothing about the truth. Requiring the bound makes
the rule fail closed: where the data cannot support a cheaper member, the expensive
best is kept. The same margin is reused as the non-inferiority margin on the test
fold, so the rule and the verdict speak about one quantity.

**The baseline to beat is not the best single member; it is the frontier that
mixing two members already reaches.** Answering with member A at probability p and
member B otherwise lands exactly on the segment between their two points in the
cost-accuracy plane, and needs no router at all. So the upper-left convex hull of
the single-member points is what a router has to clear to have bought anything.
Comparing only against the best single member would credit routing for a result a
coin flip achieves.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Sequence

from . import stats
from .catalog import Member


@dataclass(frozen=True)
class Cell:
    """One member's answer to one question."""

    correct: bool
    parsed: bool
    prompt_tokens: int
    completion_tokens: int
    latency_ms: float
    failed: bool

    def cost_usd(self, member: Member) -> float:
        return member.cost_usd(self.prompt_tokens, self.completion_tokens)


@dataclass(frozen=True)
class Question:
    question_id: str
    category: str
    fold: str


@dataclass(frozen=True)
class Matrix:
    """Every member's answer to every question, plus the questions' metadata."""

    cells: dict[str, dict[str, Cell]]
    questions: dict[str, Question]
    members: dict[str, Member]

    def complete_ids(self, fold: str | None = None) -> list[str]:
        """Questions every member answered.

        An arm may only be scored where every arm could have been scored. A
        question one member failed on is dropped from all of them, because
        keeping it would compare a nine-member pool against a ten-member one and
        call the difference routing.
        """
        wanted = set(self.members)
        out = []
        for qid, row in self.cells.items():
            if fold and self.questions[qid].fold != fold:
                continue
            if wanted <= row.keys():
                out.append(qid)
        return sorted(out)

    def incomplete_ids(self, fold: str | None = None) -> list[str]:
        complete = set(self.complete_ids(fold))
        return sorted(
            qid
            for qid, question in self.questions.items()
            if (not fold or question.fold == fold) and qid not in complete
        )


class MatrixError(RuntimeError):
    """The collected calls cannot be assembled into a matrix without guessing."""


def load_matrix(
    paths: Sequence[Path], members: Sequence[Member], *, allow_duplicates: bool = False
) -> Matrix:
    """Read matrix JSONL files, keeping only successful pinned calls.

    Two things are refused rather than resolved. A repeated `(question, member)`
    cell would otherwise be decided by file order — resumes and re-runs make that
    easy to produce — and a repeated question id carrying a different category or
    fold means two datasets are colliding in one key. Either would quietly change
    which answers the report is built from, so both stop the load. Pass
    `allow_duplicates` to keep the first occurrence instead, for a deliberate
    repeat-measurement pass.
    """
    by_name = {member.name: member for member in members}
    cells: dict[str, dict[str, Cell]] = {}
    questions: dict[str, Question] = {}
    duplicates = 0

    for path in paths:
        with path.open() as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                name = row["requested_model"]
                if name not in by_name:
                    continue
                qid = row["question_id"]
                question = Question(qid, row["category"], row["fold"])
                seen = questions.setdefault(qid, question)
                if seen != question:
                    raise MatrixError(
                        f"question id {qid!r} appears as {seen} and as {question}; "
                        "two datasets are colliding in one key"
                    )
                if row.get("error"):
                    continue
                row_cells = cells.setdefault(qid, {})
                if name in row_cells:
                    duplicates += 1
                    if not allow_duplicates:
                        raise MatrixError(
                            f"cell ({qid}, {name}) appears more than once across "
                            f"{len(paths)} input file(s); which answer counts would be "
                            "decided by file order"
                        )
                    continue
                row_cells[name] = Cell(
                    correct=bool(row.get("correct")),
                    parsed=row.get("extracted") is not None,
                    prompt_tokens=int(row.get("prompt_tokens") or 0),
                    completion_tokens=int(row.get("completion_tokens") or 0),
                    latency_ms=float(row.get("latency_ms") or 0.0),
                    failed=False,
                )
    if duplicates:
        print(f"[WARNING] kept the first of {duplicates} duplicate cells")
    return Matrix(cells=cells, questions=questions, members=by_name)


@dataclass(frozen=True)
class Outcome:
    """What an arm achieved on one question."""

    question_id: str
    category: str
    member: str | None
    correct: bool
    cost_usd: float
    latency_ms: float
    # Fractional credit, for an arm defined as an expectation over members rather
    # than as one choice. Defaults to the binary outcome.
    credit: float | None = None

    @property
    def score(self) -> float:
        return self.credit if self.credit is not None else float(self.correct)


@dataclass(frozen=True)
class ArmResult:
    name: str
    outcomes: tuple[Outcome, ...]

    @property
    def accuracy(self) -> float:
        return sum(o.score for o in self.outcomes) / len(self.outcomes)

    @property
    def cost_usd(self) -> float:
        return sum(o.cost_usd for o in self.outcomes)

    @property
    def cost_per_question(self) -> float:
        return self.cost_usd / len(self.outcomes)

    def correctness(self) -> list[bool]:
        return [o.correct for o in self.outcomes]

    def selection_counts(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for outcome in self.outcomes:
            key = outcome.member or "(none)"
            counts[key] = counts.get(key, 0) + 1
        return counts


# --------------------------------------------------------------------------- #
# arms
# --------------------------------------------------------------------------- #


def pinned(matrix: Matrix, member_name: str, qids: Sequence[str]) -> ArmResult:
    member = matrix.members[member_name]
    outcomes = []
    for qid in qids:
        cell = matrix.cells[qid][member_name]
        outcomes.append(
            Outcome(
                question_id=qid,
                category=matrix.questions[qid].category,
                member=member_name,
                correct=cell.correct,
                cost_usd=cell.cost_usd(member),
                latency_ms=cell.latency_ms,
            )
        )
    return ArmResult(name=f"pinned:{member_name}", outcomes=tuple(outcomes))


def by_assignment(
    matrix: Matrix,
    qids: Sequence[str],
    choose: Callable[[str], str],
    name: str,
) -> ArmResult:
    """An arm that picks one member per question by some rule."""
    outcomes = []
    for qid in qids:
        member_name = choose(qid)
        member = matrix.members[member_name]
        cell = matrix.cells[qid][member_name]
        outcomes.append(
            Outcome(
                question_id=qid,
                category=matrix.questions[qid].category,
                member=member_name,
                correct=cell.correct,
                cost_usd=cell.cost_usd(member),
                latency_ms=cell.latency_ms,
            )
        )
    return ArmResult(name=name, outcomes=tuple(outcomes))


def oracle_answer(matrix: Matrix, qids: Sequence[str], *, cost_aware: bool) -> ArmResult:
    """Correct wherever any member was correct: an existential upper bound.

    Chosen after the answers are known, so no input-time router is guaranteed to
    reach it. Over multiple-choice questions it also rises with pool size even for
    members that know nothing, which is why it is always reported beside the
    guessing union for the same pool size.

    Two costings, reported separately because they are bounds on different things.
    `cost_aware=False` prices the answer at the mean over the correct members: the
    bound is on accuracy alone and the cost is merely what such an answer typically
    costs. `cost_aware=True` takes the cheapest correct member, which is a strictly
    stronger oracle — it has hindsight over output length as well as over
    correctness, so its cost is not a target any policy could aim at.
    """
    outcomes = []
    for qid in qids:
        row = matrix.cells[qid]
        correct_members = [name for name, cell in row.items() if cell.correct]
        pool = correct_members or list(row)
        if cost_aware:
            chosen = min(pool, key=lambda n: row[n].cost_usd(matrix.members[n]))
            cost = row[chosen].cost_usd(matrix.members[chosen])
            latency = row[chosen].latency_ms
        else:
            chosen = None
            cost = sum(row[n].cost_usd(matrix.members[n]) for n in pool) / len(pool)
            latency = sum(row[n].latency_ms for n in pool) / len(pool)
        outcomes.append(
            Outcome(
                question_id=qid,
                category=matrix.questions[qid].category,
                member=chosen,
                correct=bool(correct_members),
                cost_usd=cost,
                latency_ms=latency,
            )
        )
    name = "oracle:cheapest_correct" if cost_aware else "oracle:any_correct"
    return ArmResult(name=name, outcomes=tuple(outcomes))


def random_uniform(matrix: Matrix, qids: Sequence[str]) -> ArmResult:
    """Choosing a member uniformly at random, in expectation.

    Per question this is the mean over members, not one sampled member. The
    expectation is exactly as paired as a realised draw — the unit is still the
    question — and it carries none of the noise of a particular sequence of coin
    flips, which the bootstrap would not have covered anyway because that sequence
    is fixed across resamples.
    """
    outcomes = []
    for qid in qids:
        row = matrix.cells[qid]
        n = len(row)
        outcomes.append(
            Outcome(
                question_id=qid,
                category=matrix.questions[qid].category,
                member=None,
                correct=False,  # unused: accuracy comes from the fractional field
                cost_usd=sum(cell.cost_usd(matrix.members[m]) for m, cell in row.items()) / n,
                latency_ms=sum(cell.latency_ms for cell in row.values()) / n,
                credit=sum(1.0 for cell in row.values() if cell.correct) / n,
            )
        )
    return ArmResult(name="random:uniform", outcomes=tuple(outcomes))


# --------------------------------------------------------------------------- #
# fitting, on the calibration fold only
# --------------------------------------------------------------------------- #


def hash_seed(*parts: str) -> int:
    """A stable seed per comparison, so a refit reproduces the same tie set."""
    import hashlib

    digest = hashlib.sha256("\u0000".join(parts).encode()).digest()
    return int.from_bytes(digest[:4], "big")


@dataclass(frozen=True)
class DomainChoice:
    domain: str
    chosen: str
    tied_with: tuple[str, ...]
    best_accuracy: float
    chosen_accuracy: float
    chosen_cost_per_question: float
    n_questions: int


# How much accuracy the rule may trade away for a lower price.
#
# The rule this bounds is a confidence bound, not a point estimate, and the
# difference matters. A tie test alone admits everyone when a domain has few
# questions — nothing is significant, so the rule silently becomes "always take
# the cheapest". But a point-estimate margin is no better: at ~175 questions per
# domain the paired difference has a standard error of roughly 3pp, so "within 2pp
# of the best on this fold" does not bound the true gap at all, and reporting it as
# "gives up at most 2pp" would be false.
#
# So membership requires the *lower confidence bound* of (member - best) to sit
# above -margin. That is a claim about the truth rather than about one fold, and it
# fails closed: where the data cannot support the claim, the member is excluded and
# the expensive best is kept. The same margin is reused as the non-inferiority
# margin on the test fold, so the rule and its verdict speak about one quantity.
DEFAULT_MAX_ACCURACY_GIVEUP = 0.02

# Rounds for the per-domain bounds. Lower than the reporting default: this runs
# once per (domain, member) pair while fitting, and the bound only has to decide a
# membership question.
FIT_BOOTSTRAP_ROUNDS = 600


def fit_domain_assignment(
    matrix: Matrix,
    fold: str,
    *,
    alpha: float = 0.05,
    max_accuracy_giveup: float = DEFAULT_MAX_ACCURACY_GIVEUP,
) -> dict[str, DomainChoice]:
    """Per domain: among members tied for best and close to it, take the cheapest.

    The tie test is McNemar against the domain's most accurate member, which is
    paired and therefore the right test on the same questions. It is deliberately
    uncorrected within a domain: correcting would widen the tie set and hand the
    choice to price even more often, which biases toward the conclusion this
    benchmark is trying to test.
    """
    qids = matrix.complete_ids(fold)
    by_domain: dict[str, list[str]] = {}
    for qid in qids:
        by_domain.setdefault(matrix.questions[qid].category, []).append(qid)

    choices: dict[str, DomainChoice] = {}
    for domain, domain_qids in sorted(by_domain.items()):
        accuracy = {
            name: sum(matrix.cells[q][name].correct for q in domain_qids) / len(domain_qids)
            for name in matrix.members
        }
        best = max(accuracy, key=lambda n: accuracy[n])
        tied = []
        for name in matrix.members:
            if name == best:
                tied.append(name)
                continue
            units = [
                (
                    float(matrix.cells[q][name].correct),
                    float(matrix.cells[q][best].correct),
                )
                for q in domain_qids
            ]
            bound = stats.non_inferiority(
                units,
                _mean_difference,
                margin=max_accuracy_giveup,
                rounds=FIT_BOOTSTRAP_ROUNDS,
                alpha=alpha,
                seed=hash_seed(domain, name),
            )
            if bound.passes:
                tied.append(name)

        cost = {
            name: sum(
                matrix.cells[q][name].cost_usd(matrix.members[name]) for q in domain_qids
            )
            / len(domain_qids)
            for name in tied
        }
        chosen = min(tied, key=lambda n: (cost[n], -accuracy[n], n))
        choices[domain] = DomainChoice(
            domain=domain,
            chosen=chosen,
            tied_with=tuple(sorted(tied)),
            best_accuracy=accuracy[best],
            chosen_accuracy=accuracy[chosen],
            chosen_cost_per_question=cost[chosen],
            n_questions=len(domain_qids),
        )
    return choices


def fit_global_choice(
    matrix: Matrix,
    fold: str,
    *,
    alpha: float = 0.05,
    max_accuracy_giveup: float = DEFAULT_MAX_ACCURACY_GIVEUP,
) -> DomainChoice:
    """The same rule with no domain split: the cheapest member tied for best.

    This separates "routing helped" from "the rule helped": if the per-domain arm
    and this one land in the same place, the domain split bought nothing.
    """
    qids = matrix.complete_ids(fold)
    accuracy = {
        name: sum(matrix.cells[q][name].correct for q in qids) / len(qids)
        for name in matrix.members
    }
    best = max(accuracy, key=lambda n: accuracy[n])
    tied = [best]
    for name in matrix.members:
        if name == best:
            continue
        units = [
            (float(matrix.cells[q][name].correct), float(matrix.cells[q][best].correct))
            for q in qids
        ]
        bound = stats.non_inferiority(
            units,
            _mean_difference,
            margin=max_accuracy_giveup,
            rounds=FIT_BOOTSTRAP_ROUNDS,
            alpha=alpha,
            seed=hash_seed("(global)", name),
        )
        if bound.passes:
            tied.append(name)
    cost = {
        name: sum(matrix.cells[q][name].cost_usd(matrix.members[name]) for q in qids)
        / len(qids)
        for name in tied
    }
    chosen = min(tied, key=lambda n: (cost[n], -accuracy[n], n))
    return DomainChoice(
        domain="(global)",
        chosen=chosen,
        tied_with=tuple(sorted(tied)),
        best_accuracy=accuracy[best],
        chosen_accuracy=accuracy[chosen],
        chosen_cost_per_question=cost[chosen],
        n_questions=len(qids),
    )


def best_single_by_accuracy(matrix: Matrix, fold: str) -> str:
    """The most accurate member on a fold, chosen without looking at the test fold.

    Reported separately from the most accurate member *on* the test fold: picking
    the winner after seeing the scores is a different, and flattering, number.
    """
    qids = matrix.complete_ids(fold)
    return max(
        matrix.members,
        key=lambda n: sum(matrix.cells[q][n].correct for q in qids) / len(qids),
    )


# --------------------------------------------------------------------------- #
# the frontier a coin flip already reaches
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class Point:
    label: str
    cost_per_question: float
    accuracy: float


def mixture_frontier(points: Sequence[Point]) -> list[Point]:
    """Upper-left convex hull: what mixing single members already achieves.

    Answering with one member at probability p and another otherwise lands on the
    segment between their points, so every point on this hull is available without
    a router. Only a point strictly above it is evidence that routing bought
    something.

    The hull is a chain of maxima, so on noisy data it sits above the truth. That
    biases every gap-to-hull downward — against the router. Two things follow, and
    both are done rather than noted: the reported hull is built on the fold the
    policy was fitted on, so the router and its baseline are held to the same
    discipline, and the gap is put through a bootstrap that rebuilds the hull inside
    every resample so its own uncertainty is carried (`frontier_gap_interval`).
    """
    ordered = sorted(points, key=lambda p: (p.cost_per_question, -p.accuracy))
    hull: list[Point] = []
    for point in ordered:
        # Dominated: something at least as cheap is at least as accurate.
        if hull and point.accuracy <= hull[-1].accuracy:
            continue
        while len(hull) >= 2 and not _is_concave_corner(hull[-2], hull[-1], point):
            hull.pop()
        hull.append(point)
    return hull


def _is_concave_corner(a: Point, b: Point, c: Point) -> bool:
    """Whether b lies strictly above the segment a-c, so it belongs on the hull.

    If it does not, b is reachable by mixing a and c and is dropped.
    """
    cross = (b.cost_per_question - a.cost_per_question) * (c.accuracy - a.accuracy) - (
        b.accuracy - a.accuracy
    ) * (c.cost_per_question - a.cost_per_question)
    return cross < 0


def frontier_accuracy_at(hull: Sequence[Point], cost: float) -> float | None:
    """Accuracy the mixture frontier reaches at a given cost per question."""
    if not hull:
        return None
    if cost <= hull[0].cost_per_question:
        return hull[0].accuracy if cost >= hull[0].cost_per_question else None
    if cost >= hull[-1].cost_per_question:
        return hull[-1].accuracy
    for left, right in zip(hull, hull[1:]):
        if left.cost_per_question <= cost <= right.cost_per_question:
            span = right.cost_per_question - left.cost_per_question
            if span == 0:
                return max(left.accuracy, right.accuracy)
            weight = (cost - left.cost_per_question) / span
            return left.accuracy + weight * (right.accuracy - left.accuracy)
    return None


def frontier_gap_interval(
    matrix: Matrix,
    arm: ArmResult,
    qids: Sequence[str],
    *,
    rounds: int = 600,
    alpha: float = 0.05,
    seed: int = 5150,
) -> stats.Interval:
    """How far an arm sits above the mixture frontier, with the hull resampled too.

    The hull is estimated from the same questions as the arm, so treating it as a
    fixed line understates the uncertainty and — because a hull is a chain of
    maxima — biases the gap against the arm. Here every resample rebuilds both: the
    single-member points and the arm's accuracy are recomputed on the resampled
    questions, the hull is refitted, and the gap is measured against that. The
    interval that comes out is about the comparison rather than about the arm alone.
    """
    import random

    arm_by_id = {o.question_id: o for o in arm.outcomes}
    shared = [q for q in qids if q in arm_by_id]
    if not shared:
        raise ValueError("the arm answered none of these questions")

    by_stratum: dict[str, list[str]] = {}
    for qid in shared:
        by_stratum.setdefault(matrix.questions[qid].category, []).append(qid)

    def gap_for(sample: Sequence[str]) -> float:
        n = len(sample)
        points = []
        for name in matrix.members:
            member = matrix.members[name]
            correct = sum(matrix.cells[q][name].correct for q in sample) / n
            cost = sum(matrix.cells[q][name].cost_usd(member) for q in sample) / n
            points.append(Point(label=name, cost_per_question=cost, accuracy=correct))
        hull = mixture_frontier(points)
        arm_accuracy = sum(arm_by_id[q].score for q in sample) / n
        arm_cost = sum(arm_by_id[q].cost_usd for q in sample) / n
        reachable = frontier_accuracy_at(hull, arm_cost)
        if reachable is None:
            # Cheaper than every single member: the frontier says nothing there.
            return float("nan")
        return arm_accuracy - reachable

    point = gap_for(shared)
    rng = random.Random(seed)
    draws = []
    for _ in range(rounds):
        sample: list[str] = []
        for group in by_stratum.values():
            size = len(group)
            sample.extend(group[rng.randrange(size)] for _ in range(size))
        value = gap_for(sample)
        if value == value:  # skip NaN
            draws.append(value)
    if not draws:
        return stats.Interval(point=point, low=float("nan"), high=float("nan"))
    draws.sort()
    return stats.Interval(
        point=point,
        low=draws[int((alpha / 2) * (len(draws) - 1))],
        high=draws[int((1 - alpha / 2) * (len(draws) - 1))],
    )


def spend_report(paths: Sequence[Path], members: Sequence[Member]) -> dict[str, object]:
    """What these runs actually consumed, from the recorded calls.

    Attribution has to come from the harness's own records rather than from the
    difference in the gateway balance, because the balance is shared. Second-opinion
    tooling routed through the same gateway is charged to the same pool, and during
    this project a couple of code reviews sent through it cost more than the
    measurement did — so a balance delta read as "what the benchmark cost" would
    have been several times too high.

    Retried attempts are the known gap in the other direction: a call that failed
    reports no usage, so its tokens are billed and not counted here.
    """
    by_name = {member.name: member for member in members}
    total_tokens = 0
    charged_tokens = 0
    charged_cost = 0.0
    calls = 0
    retried = 0
    for path in paths:
        with path.open() as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                calls += 1
                if int(row.get("attempts") or 1) > 1:
                    retried += 1
                if row.get("error"):
                    continue
                tokens = int(row.get("total_tokens") or 0)
                total_tokens += tokens
                member = by_name.get(row.get("requested_model"))
                # Self-hosted members do not draw on the gateway balance.
                if member is not None and member.transport == "gateway":
                    charged_tokens += tokens
                    charged_cost += member.cost_usd(
                        int(row.get("prompt_tokens") or 0),
                        int(row.get("completion_tokens") or 0),
                    )
    return {
        "calls": calls,
        "retried_calls": retried,
        "tokens": total_tokens,
        "gateway_charged_tokens": charged_tokens,
        "gateway_cost_usd": charged_cost,
    }


def served_models(
    paths: Sequence[Path], members: Sequence[Member]
) -> dict[str, dict[str, int]]:
    """Which upstream model id actually answered for each pool member.

    An alias can be repointed underneath us between a calibration run and a test
    run, and the interleaved run order is designed to keep that out of the
    comparison — but it cannot detect it. This can: more than one served id under
    one member name means the member was not the same model throughout, and the two
    folds are not measuring the same thing.
    """
    # Pinned members only. A routed arm names the router's entrypoint, which is
    # served by whichever member the selector chose — many ids under one name is
    # the point there, not a drift.
    wanted = {member.name for member in members}
    out: dict[str, dict[str, int]] = {}
    for path in paths:
        with path.open() as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                if row.get("error") or row["requested_model"] not in wanted:
                    continue
                served = row.get("served_model")
                if not served:
                    continue
                bucket = out.setdefault(row["requested_model"], {})
                bucket[served] = bucket.get(served, 0) + 1
    return out


def response_path_counts(paths: Sequence[Path]) -> dict[str, int]:
    """How many calls were answered upstream, and how many by something else.

    The router runs a semantic cache, and its own startup log says so. A cache hit
    carries the latency and the cost of nothing, and the paired design invites hits
    by asking every member the same question — so this is not a detail to assume
    away. The router reports the path it took per response, and the invariant that
    every scored call was answered upstream is checked rather than believed.
    """
    counts: dict[str, int] = {}
    for path in paths:
        with path.open() as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                if row.get("error"):
                    continue
                where = (row.get("headers") or {}).get("vsr_response_path", "(absent)")
                counts[where] = counts.get(where, 0) + 1
    return counts


def flip_rates(
    repeat_paths: Sequence[Path], matrix: Matrix
) -> dict[str, dict[str, float | int]]:
    """Per member, how often a re-asked question changed its verdict.

    The matrix holds one sample per cell. No temperature was sent — no value is legal
    across this pool — so each member decodes at its own default and none of them is
    promised to be deterministic. A flip rate of f per cell inflates the existential
    bound in particular, because "did anyone get this right" gains from every
    independent flip, which is the one bound most likely to be over-read.
    """
    out: dict[str, dict[str, float | int]] = {}
    for path in repeat_paths:
        with path.open() as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                arm = str(row.get("arm", ""))
                if not arm.startswith("repeat:") or row.get("error"):
                    continue
                name = row["requested_model"]
                original = matrix.cells.get(row["question_id"], {}).get(name)
                if original is None:
                    continue
                bucket = out.setdefault(name, {"compared": 0, "flipped": 0})
                bucket["compared"] += 1
                if bool(row.get("correct")) != original.correct:
                    bucket["flipped"] += 1
    for bucket in out.values():
        bucket["rate"] = (
            bucket["flipped"] / bucket["compared"] if bucket["compared"] else 0.0
        )
    return out


# Exchange rates between an accuracy point and a dollar, for the utility the
# routability blade is measured on. `utility = accuracy - lambda * cost_usd`, so
# lambda is 0.01 divided by what one accuracy point is worth per question:
# lambda=5 values a point at $0.002 a question, lambda=100 at $0.0001. Zero is pure
# accuracy. The grid is swept rather than chosen because the answer depends on it —
# and finding that it does is itself the result.
DEFAULT_LAMBDA_GRID = (0.0, 5.0, 20.0, 100.0)


@dataclass(frozen=True)
class RoutabilityDiagnostic:
    """Whether a feature-conditioned router could ever have helped this pool.

    The question a negative routing result has to answer is which of two things
    happened: the feature carried signal and the fitting missed it, or there was no
    signal to fit. This separates them, and it costs nothing beyond the matrix.

    `ceiling` picks the best member per bucket *with hindsight on the scored fold*,
    which is an upper bound for any policy conditioned on that feature.
    `null_ceiling` is the same quantity after the labels are shuffled, which is what
    "best of ten per bucket" reaches from selection alone. When the two coincide, no
    amount of calibration data would have helped.

    The blade is measured on a utility, not on accuracy, and that choice decides the
    answer. A feature that predicts *difficulty* rather than *which arm wins* moves
    an accuracy ceiling not at all — every bucket still prefers the same strongest
    arm — while being exactly what cost-aware routing lives on: send the easy bucket
    somewhere cheap. Scoring the blade on accuracy alone therefore reports "no
    signal" for the features most likely to pay. Measured here on MMLU-Pro domains:
    p = 0.56 at lambda = 0, and p < 0.001 from lambda = 20 up.
    """

    lambda_: float
    best_single: str
    best_single_utility: float
    ceiling: float
    null_ceiling_mean: float
    null_ceiling_p95: float
    p_value: float
    mean_abs_interaction: float

    @property
    def headroom(self) -> float:
        return self.ceiling - self.best_single_utility

    def verdict(self) -> str:
        if self.p_value > 0.10:
            return "no signal beyond selection alone at this exchange rate"
        return "signal beyond selection alone"


def routability(
    matrix: Matrix,
    fold: str,
    *,
    lambda_: float = 0.0,
    rounds: int = 2000,
    seed: int = 7,
    labels: dict[str, str] | None = None,
) -> RoutabilityDiagnostic:
    """Ceiling for a feature-conditioned policy, against a shuffled-label null.

    `labels` defaults to the dataset's own category; pass another mapping to put the
    same blade to a different candidate feature.
    """
    import random

    qids = matrix.complete_ids(fold)
    names = sorted(matrix.members)
    true_labels = labels or {q: matrix.questions[q].category for q in qids}
    buckets = sorted({true_labels[q] for q in qids})

    def utility(qid: str, name: str) -> float:
        cell = matrix.cells[qid][name]
        return float(cell.correct) - lambda_ * cell.cost_usd(matrix.members[name])

    own = {n: sum(utility(q, n) for q in qids) / len(qids) for n in names}
    best_single = max(names, key=lambda n: own[n])

    def ceiling_for(assigned: dict[str, str]) -> float:
        total = 0.0
        for bucket in buckets:
            subset = [q for q in qids if assigned[q] == bucket]
            if subset:
                total += max(sum(utility(q, n) for q in subset) for n in names)
        return total / len(qids)

    ceiling = ceiling_for(true_labels)

    rng = random.Random(seed)
    pool = [true_labels[q] for q in qids]
    null = []
    for _ in range(rounds):
        rng.shuffle(pool)
        null.append(ceiling_for(dict(zip(qids, pool))))
    null.sort()

    # How much each member deviates from its own average within a bucket. Large
    # values here look like per-bucket strength but are mostly the bucket being easy
    # or hard for everyone, which is shared and therefore unroutable.
    deviations = []
    for name in names:
        for bucket in buckets:
            subset = [q for q in qids if true_labels[q] == bucket]
            if subset:
                deviations.append(
                    abs(sum(utility(q, name) for q in subset) / len(subset) - own[name])
                )

    return RoutabilityDiagnostic(
        lambda_=lambda_,
        best_single=best_single,
        best_single_utility=own[best_single],
        ceiling=ceiling,
        null_ceiling_mean=sum(null) / len(null),
        null_ceiling_p95=null[int(0.95 * (len(null) - 1))],
        p_value=sum(1 for v in null if v >= ceiling) / len(null),
        mean_abs_interaction=sum(deviations) / len(deviations),
    )


def arm_set_value(matrix: Matrix, qids: Sequence[str], depth: int = 6) -> list[tuple[str, float]]:
    """Existential ceiling as members are added greedily, best first.

    Answers "how many members does the pool actually need". If two members reach most
    of what ten reach, the rest are paying for coverage nobody uses, and pruning is
    justified before any routing question is asked.
    """
    chosen: list[str] = []
    remaining = sorted(matrix.members)
    out = []
    for _ in range(min(depth, len(remaining))):
        best_name, best_value = None, -1.0
        for name in remaining:
            trial = chosen + [name]
            value = sum(
                1 for q in qids if any(matrix.cells[q][m].correct for m in trial)
            ) / len(qids)
            if value > best_value:
                best_name, best_value = name, value
        chosen.append(best_name)
        remaining.remove(best_name)
        out.append((best_name, best_value))
    return out


def error_overlap(matrix: Matrix, qids: Sequence[str], top: int = 5) -> list[tuple[str, str, float, int]]:
    """Pairwise agreement among the strongest members.

    Routing can only pay where members fail on different questions. This reports
    the phi coefficient and the count of questions exactly one of the pair answered
    — the complementarity budget, in questions rather than in principle.
    """
    names = sorted(
        matrix.members,
        key=lambda n: -sum(matrix.cells[q][n].correct for q in qids),
    )[:top]
    out = []
    for i, a in enumerate(names):
        for b in names[i + 1 :]:
            n11 = n00 = n10 = n01 = 0
            for q in qids:
                x, y = matrix.cells[q][a].correct, matrix.cells[q][b].correct
                if x and y:
                    n11 += 1
                elif not x and not y:
                    n00 += 1
                elif x:
                    n10 += 1
                else:
                    n01 += 1
            denominator = ((n11 + n10) * (n01 + n00) * (n11 + n01) * (n10 + n00)) ** 0.5
            phi = (n11 * n00 - n10 * n01) / denominator if denominator else 0.0
            out.append((a, b, phi, n10 + n01))
    return out


def deletion_audit(matrix: Matrix, fold: str) -> dict[str, float | int]:
    """Whether the questions dropped for incompleteness were the harder ones.

    Complete-case analysis is only neutral if the missing cells are missing at
    random, and they are not: a call fails on timeout, and timeouts fall on the
    long, hard questions. If the dropped set is harder than the kept set, every
    arm's accuracy is inflated and the existential bound most of all. This reports
    the comparison rather than asserting it is fine.
    """
    kept = matrix.complete_ids(fold)
    dropped = matrix.incomplete_ids(fold)

    def mean_accuracy(qids: Sequence[str]) -> float | None:
        scores = [
            sum(cell.correct for cell in matrix.cells[q].values()) / len(matrix.cells[q])
            for q in qids
            if matrix.cells.get(q)
        ]
        return sum(scores) / len(scores) if scores else None

    return {
        "kept": len(kept),
        "dropped": len(dropped),
        "kept_mean_member_accuracy": mean_accuracy(kept),
        "dropped_mean_member_accuracy": mean_accuracy(dropped),
    }


def gap_coverage(arm: float, baseline: float, upper: float) -> float | None:
    """Where an arm sits between a baseline and an upper bound, as a fraction.

    Reported instead of "reached X% of the oracle", which reads as though the
    bound were a target that could be approached by trying harder.
    """
    if upper <= baseline:
        return None
    return (arm - baseline) / (upper - baseline)


def _paired_units(
    a: ArmResult, b: ArmResult, field: str
) -> tuple[list[tuple[float, float]], list[str]]:
    """Per-question pairs of one field, over the questions both arms answered."""
    a_by_id = {o.question_id: o for o in a.outcomes}
    b_by_id = {o.question_id: o for o in b.outcomes}
    shared = sorted(a_by_id.keys() & b_by_id.keys())
    units = [
        (getattr(a_by_id[q], field), getattr(b_by_id[q], field)) for q in shared
    ]
    strata = [a_by_id[q].category for q in shared]
    return units, strata


def _mean_difference(sample: Sequence[object]) -> float:
    if not sample:
        return 0.0
    n = len(sample)
    return sum(x for x, _ in sample) / n - sum(y for _, y in sample) / n


def paired_accuracy_delta(
    a: ArmResult, b: ArmResult, *, rounds: int = 2000, seed: int = 4242
) -> stats.Interval:
    """Accuracy difference a - b over the questions both answered."""
    units, strata = _paired_units(a, b, "score")
    return stats.paired_bootstrap(
        units, _mean_difference, rounds=rounds, seed=seed, strata=strata
    )


def paired_cost_delta(
    a: ArmResult, b: ArmResult, *, rounds: int = 2000, seed: int = 4243
) -> stats.Interval:
    """Cost-per-question difference a - b over the questions both answered."""
    units, strata = _paired_units(a, b, "cost_usd")
    return stats.paired_bootstrap(
        units, _mean_difference, rounds=rounds, seed=seed, strata=strata
    )


def paired_latency_delta(
    a: ArmResult, b: ArmResult, *, rounds: int = 2000, seed: int = 4244
) -> stats.Interval:
    """Latency difference a - b, the price usually paid for a cost saving."""
    units, strata = _paired_units(a, b, "latency_ms")
    return stats.paired_bootstrap(
        units, _mean_difference, rounds=rounds, seed=seed, strata=strata
    )


def paired_accuracy_p_value(
    a: ArmResult, b: ArmResult, *, rounds: int = 2000, seed: int = 4242
) -> float:
    """Two-sided p-value for "these two arms are equally accurate"."""
    units, strata = _paired_units(a, b, "score")
    return stats.bootstrap_p_value(
        units, _mean_difference, rounds=rounds, seed=seed, strata=strata
    )


def accuracy_non_inferiority(
    a: ArmResult,
    b: ArmResult,
    *,
    margin: float,
    rounds: int = 2000,
    seed: int = 4242,
) -> stats.NonInferiority:
    """Is arm a no less accurate than b, beyond a margin fixed in advance?

    This is what the claim "as accurate, for less money" requires. A two-sided
    interval containing zero says only that the data cannot resolve the
    difference.
    """
    units, strata = _paired_units(a, b, "score")
    return stats.non_inferiority(
        units, _mean_difference, margin=margin, rounds=rounds, seed=seed, strata=strata
    )


def parse_failure_rates(matrix: Matrix, qids: Iterable[str]) -> dict[str, float]:
    """Per member, the share of answers no letter could be read from.

    An audit, not a metric: a rate that differs across members means some of the
    accuracy column is answer formatting rather than knowledge, and the comparison
    is contaminated until it is fixed.
    """
    qids = list(qids)
    return {
        name: sum(1 for q in qids if not matrix.cells[q][name].parsed) / len(qids)
        for name in matrix.members
    }
