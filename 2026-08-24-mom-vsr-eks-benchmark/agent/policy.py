"""Who takes the next step, why, and what it costs. No network, no container.

Everything in this module is a decision made from things already in the log, so it can be
tested without spending anything — which is the point, because a mistake in any of it
produces a number that looks like a model result. The three parts:

**The triggers.** All three are computable from the log with no extra model call: a test
failing, the same action repeated, a budget exceeded. Self-reported confidence is
excluded, and so is cheap-model disagreement — v1 measured strong arms' errors as highly
correlated, so a second opinion would rarely fire and would agree when wrong, at the cost
of standing up a second full context every time it was consulted.

**One-way escalation.** `docs/SWITCH-ECONOMICS.md` measured the switch tax: one escalation
in a 60-step session saves 63%, eight spot escalations cost 33% *more* than never leaving
the premium model. So escalation is a latch, and it is a latch in code rather than a
convention in a prompt.

**Two mechanisms, not one.** The tax is charged for handing over the conversation, not for
using a cheap model. A self-contained request with its own small context pays no tax at
all, which is why the role-based policy hands the decisive step to a premium model as a
fresh call rather than escalating the thread into it. The two policies are therefore not
variants of each other, and their costs have nothing in common.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Sequence

import tools

SELF_HOSTED, CHEAP, PREMIUM = "self_hosted", "cheap", "premium"

# The two jobs in a role-based episode. Roles rather than tiers, because which tier does the
# investigating is a run-time choice — `--worker-tier self_hosted` puts it on the paid-for
# GPU — and a table written in tiers made that choice withhold every tool from the worker,
# leaving it with nothing to do.
WORKER, DECIDER = "worker", "decider"

# Pre-registered, before any episode ran: which tier each kind of step belongs to. Written
# here rather than passed in as a flag, because a table chosen after seeing the results is
# a fitted model presented as a design.
ROLE_TABLE = {
    "search": WORKER,
    "read": WORKER,
    "verify": WORKER,
    "patch": DECIDER,
    "handoff": WORKER,
    "finish": WORKER,
}


def decider_tools() -> tuple[str, ...]:
    """Tools the table reserves for the decisive tier, and so withholds from the worker.

    This is what makes the table load-bearing rather than decorative. A step type cannot be
    routed by choosing a model *before* the model says what it wants to do, so the table is
    applied the only way it can be: a tool the table marks decisive is not offered to the
    worker, and reaching it costs a handoff. Move `verify` to `DECIDER` and `run_tests`
    leaves too; move `patch` to `WORKER` and the worker keeps it.
    """
    return tuple(
        sorted(
            tool
            for tool, step_type in tools.STEP_TYPE.items()
            if tool in tools.DEFAULT_TOOLS and ROLE_TABLE.get(step_type) == DECIDER
        )
    )


@dataclass(frozen=True)
class Rate:
    """A million tokens in each of the four ways they get billed.

    Read from the gateway's own `pricing.json`, the same file `bench/switch_economics.py`
    reads, so the desk calculation and the measured run cannot disagree about a price.
    """

    key: str
    fresh_in: float
    out: float
    cache_read: float
    cache_write: float

    @classmethod
    def table(cls, pricing_json: Path) -> dict[str, "Rate"]:
        rates = json.loads(Path(pricing_json).read_text())["rates"]
        return {
            key: cls(
                key=key,
                fresh_in=entry["input_per_mtok_microusd"] / 1e6,
                out=entry["output_per_mtok_microusd"] / 1e6,
                cache_read=entry["cache_read_per_mtok_microusd"] / 1e6,
                cache_write=entry["cache_write_per_mtok_microusd"] / 1e6,
            )
            for key, entry in rates.items()
        }


def call_cost(
    rate: Rate,
    *,
    fresh_in: int,
    cache_read: int,
    cache_write: int,
    out: int,
) -> float:
    """What one call is billed, from the four counts the provider reported.

    Measured rather than modelled: these are the numbers in the usage block. A cache read
    at a tenth of fresh input is the whole reason a long premium session is cheaper than
    its list price, so collapsing the four into "prompt tokens" would overstate what
    switching can save.
    """
    return (
        fresh_in * rate.fresh_in
        + cache_read * rate.cache_read
        + cache_write * rate.cache_write
        + out * rate.out
    ) / 1e6


def switch_tax_usd(rate: Rate, *, fresh_in: int, cache_write: int) -> float:
    """What this turn cost over what it would have cost with its input already cached.

    Read from the turn's own usage block rather than reconstructed from the previous turn's
    token count, which was neither the prefix (it included that turn's own cached input) nor
    complete (it missed the last exchange) and could be an approximation from a broken
    stream. Here every quantity is one the provider reported about this call.

    It is an upper bound, and deliberately labelled as one: a warm model would still have
    paid the fresh price for the turn's own new material, which is inside `fresh_in`. The
    tax is the term that decides whether the whole strategy can pay for itself, so where a
    choice remains it is made against the strategy.
    """
    return (
        fresh_in * (rate.fresh_in - rate.cache_read)
        + cache_write * (rate.cache_write - rate.cache_read)
    ) / 1e6


@dataclass(frozen=True)
class Model:
    """One tier's model: where to ask, what to ask for, and what it is charged as.

    The address is per tier because the tiers are not all on one surface: the paid models
    are reached through the gateway and the self-hosted one is an in-cluster server, and a
    single endpoint would have quietly asked the gateway for a model it has never heard of.

    The price is per tier for a sharper reason. The gateway's rate table prices the
    self-hosted key at the top tier because Bedrock publishes no list price for it, and it
    prices a generic `vllm` key at $0.20 per million — neither is what the machine costs.
    The measured figure is $10.68 per million output tokens at the knee, so a tier may
    carry an explicit rate, and one that does must say where the number came from.
    """

    tier: str
    name: str
    pricing_key: str | None = None
    effort: str | None = None
    url: str | None = None
    # Which wire this tier speaks: "chat" or "responses". A tier property because it follows from
    # what the tier needs -- gpt-5.6-terra can only have both function tools and reasoning on the
    # Responses API -- and not from a switch on the run.
    api: str = "chat"
    # Passed to the server as `chat_template_kwargs`. The self-hosted deployment starts with
    # `--default-chat-template-kwargs={"enable_thinking": false}`, so the box was answering without
    # thinking while gpt-5.6-terra spent 80% of its output tokens on reasoning -- the same asymmetry
    # this harness refused to accept in the other direction. Per tier and per request, because it is
    # a property of the arm and needs no redeployment.
    template_kwargs: dict | None = None
    api_key_env: str | None = None
    rate: "Rate | None" = None
    rate_basis: str | None = None


@dataclass(frozen=True)
class Roster:
    """The three tiers a policy can choose between."""

    premium: Model
    cheap: Model
    self_hosted: Model | None = None

    def of(self, tier: str) -> Model:
        if tier == PREMIUM:
            return self.premium
        if tier == CHEAP:
            return self.cheap
        if tier == SELF_HOSTED and self.self_hosted is not None:
            return self.self_hosted
        # A policy asking for a tier the run does not have would otherwise silently fall
        # back and be reported under the wrong name.
        raise KeyError(f"this run has no {tier!r} tier")


@dataclass(frozen=True)
class Budget:
    """The deterministic backstop, and what counts as a loop.

    `max_steps` and `max_tokens` are the experimental condition: every policy gets the same
    number of turns, which is what makes the comparison paired.

    `max_usd` is *not* an experimental condition and must not be allowed to become one. A
    single dollar ceiling binds the premium baseline first, by construction, so a ceiling
    that ever binds hands the non-inferiority claim a free win. It is a runaway guard, set
    well above any episode this design expects, and an episode that hits it is marked not
    comparable rather than counted as a failure. `docs/V3-PLAN.md` records that as a
    pre-registered exclusion, not a judgement made after seeing which arm hit it.

    `escalate_at` is the fraction of the step or token budget at which the third trigger
    fires. Named here rather than buried in the trigger, so changing it cannot leave the
    trigger's own name lying about what it measures.
    """

    max_steps: int = 40
    max_tokens: int = 400_000
    repeat_k: int = 3
    max_usd: float = 20.0
    escalate_at: float = 0.75
    # A handoff pays no switch tax, so it may happen more than once — but not without
    # bound, or a worker that cannot recognise a finished job spends the premium tier in a
    # loop.
    max_handoffs: int = 3


@dataclass
class EpisodeState:
    """What has happened so far. Everything a trigger reads lives here."""

    steps: int = 0
    tokens_in: int = 0
    tokens_out: int = 0
    spend_usd: float = 0.0
    signatures: list[str] = field(default_factory=list)
    verify_failures: int = 0
    last_tests_passed: bool | None = None
    # Whether the agent has changed anything yet. The first trigger is "the verifier
    # disagrees", and before any edit exists a failing test is the bug being reported, not
    # a disagreement with the agent's work — firing there escalates every episode on its
    # first test run and measures nothing.
    has_patched: bool = False
    # Per tier, because it is read as evidence about a tier. A shared counter let the cheap
    # model's three format mistakes withdraw the self-hosted machine, and the log then
    # explained that as a fault of the GPU.
    malformed_streak_by_tier: dict = field(default_factory=dict)
    # Turns that produced no usable action because the call itself failed. Counted apart
    # from `malformed_streak`, because withdrawing a tier for "unparseable turns" when the
    # network was at fault turns a model comparison into a network measurement.
    transport_failures: int = 0
    # None until the thread is handed to the premium model, then never unset.
    escalated_at: int | None = None
    triggers_fired: list[dict] = field(default_factory=list)

    @property
    def escalated(self) -> bool:
        return self.escalated_at is not None

    def malformed_streak(self, tier: str) -> int:
        return self.malformed_streak_by_tier.get(tier, 0)

    def note_malformed(self, tier: str) -> None:
        self.malformed_streak_by_tier[tier] = self.malformed_streak(tier) + 1

    def clear_malformed(self, tier: str) -> None:
        self.malformed_streak_by_tier[tier] = 0

    def repeated_tail(self) -> int:
        """How many times the most recent action has just been repeated."""
        if not self.signatures:
            return 0
        last = self.signatures[-1]
        count = 0
        for signature in reversed(self.signatures):
            if signature != last:
                break
            count += 1
        return count

    def escalate(self, reasons: Sequence[str]) -> bool:
        """Latch the escalation. Returns whether this call is the one that did it."""
        if self.escalated:
            return False
        self.escalated_at = self.steps
        self.triggers_fired.append({"step": self.steps, "reasons": list(reasons)})
        return True


def fired_triggers(state: EpisodeState, budget: Budget) -> tuple[str, ...]:
    """Which of the three pre-registered triggers are currently true.

    Order is meaningless — several can hold at once and all of them are recorded, because
    which trigger fires first is one of the four things the pilot is meant to measure.
    """
    reasons: list[str] = []
    if state.last_tests_passed is False and state.has_patched:
        reasons.append("verifier_disagreed")
    if state.repeated_tail() >= budget.repeat_k:
        reasons.append(f"same_action_{state.repeated_tail()}x")
    share = f"{budget.escalate_at:.0%}"
    if state.steps >= budget.max_steps * budget.escalate_at:
        reasons.append(f"step_budget_{share}")
    if state.tokens_in + state.tokens_out >= budget.max_tokens * budget.escalate_at:
        reasons.append(f"token_budget_{share}")
    return tuple(reasons)


def exhausted(state: EpisodeState, budget: Budget) -> str | None:
    """Why the episode has to stop, or None to keep going.

    The spend ceiling is here rather than in the runner because a policy that fails by
    running out of money has still spent it, and the episode has to be recorded as a
    failure with that cost attached — a cheap arm that quietly stops early would otherwise
    look like the cheapest way to solve nothing.
    """
    if state.steps >= budget.max_steps:
        return "step budget exhausted"
    if state.tokens_in + state.tokens_out >= budget.max_tokens:
        return "token budget exhausted"
    if state.spend_usd >= budget.max_usd:
        return "spend ceiling reached"
    return None


@dataclass(frozen=True)
class Decision:
    """Which tier takes the next turn, and why that one.

    The reason is not commentary. "The self-hosted machine was full" and "the metrics
    endpoint could not be read" produce the same route and mean completely different
    things about the run, and without the reason on the row a capacity-first episode that
    never touched the GPU is indistinguishable from one that did.
    """

    tier: str
    reason: str


class Policy:
    """How a policy picks the tier for the next main-thread turn."""

    name = "abstract"
    # Every tier this policy might route to. Declared, so a run can refuse at the start
    # rather than crash at step thirty with the money already spent. An earlier version
    # inferred this from the policy's type in the driver, which meant a new policy silently
    # got the wrong answer.
    required_tiers: tuple[str, ...] = (CHEAP,)
    # Whether the decisive step leaves the thread as a fresh, self-contained request.
    hands_off_patch = False

    @property
    def withholds(self) -> tuple[str, ...]:
        """Tools this policy does not offer the worker."""
        return ()

    def decide(self, state: EpisodeState) -> Decision:
        raise NotImplementedError

    def patch_tier(self) -> str:
        """Who writes the patch when the worker hands off.

        Refused rather than defaulted: a policy that withholds `write_patch` without saying
        where the patch comes from would fail at the moment the worker hands off, which is
        the most expensive moment in the episode.
        """
        raise NotImplementedError(f"{self.name} does not hand the patch off")

    def consider(self, state: EpisodeState, budget: Budget) -> tuple[str, ...]:
        """Update the escalation latch. Returns the reasons, empty if nothing fired."""
        return ()

    def describe(self) -> str:
        return self.name


class PremiumOnly(Policy):
    """The baseline: what an operator pays today."""

    name = "premium-always"
    required_tiers = (PREMIUM,)

    def decide(self, state: EpisodeState) -> Decision:
        return Decision(PREMIUM, "the policy uses one tier throughout")


class CheapOnly(Policy):
    """The floor: how much quality is lost by never paying for the premium tier."""

    name = "cheap-always"
    required_tiers = (CHEAP,)

    def decide(self, state: EpisodeState) -> Decision:
        return Decision(CHEAP, "the policy uses one tier throughout")


class SelfHostedOnly(Policy):
    """The box alone, all the way, which is the arm the pilot was missing.

    `capacity-first` sends to the box and spills to the cheap tier when there is no room, so an episode under it
    is only a box trajectory when it happened not to spill. That made the box's trajectory a by-product of
    admission control rather than something measured, and a comparison of *trajectories* — how many turns each
    model needs for the same task — has to hold the model fixed for the whole episode. On the same instances the
    box took 27 steps where the cheap tier took 8, so the difference is not a detail.
    """

    name = "self-hosted-always"
    required_tiers = (SELF_HOSTED,)

    def decide(self, state: EpisodeState) -> Decision:
        return Decision(SELF_HOSTED, "the policy uses one tier throughout")


class OneWayEscalation(Policy):
    """Cheap until a trigger fires, premium from then on, and never back.

    The latch is the finding, not a simplification: round trips pay the accumulated
    context again each way, and at eight spot calls in a 60-step session that is more
    expensive than having used the premium model the whole time.
    """

    name = "cheap-then-escalate"
    required_tiers = (CHEAP, PREMIUM)

    def decide(self, state: EpisodeState) -> Decision:
        if state.escalated:
            return Decision(PREMIUM, f"escalated at step {state.escalated_at}, one-way")
        return Decision(CHEAP, "no trigger has fired")

    def consider(self, state: EpisodeState, budget: Budget) -> tuple[str, ...]:
        if state.escalated:
            return ()
        reasons = fired_triggers(state, budget)
        if reasons and state.escalate(reasons):
            return reasons
        return ()


class CapacityFirst(Policy):
    """Fill the GPU that is billed whether or not a request arrives.

    Its marginal cost below the throughput ceiling is zero, which is the entire argument
    for the policy — measured realised price on an idle machine is about $4,500 per million
    output tokens, and the same machine at the knee is $10.68. So admission control, not
    price comparison: send while there is room, spill when there is not.

    Spilling on an *unreadable* in-flight count is deliberate. Sending into a queue whose
    depth is unknown records the queue as the model's latency, which is exactly the mistake
    that made this arm look dominated in v1 when the real cause was `--max-num-seqs=2`. It
    is also the failure that could quietly turn this policy into `cheap-always`, so the
    reason travels with the decision and the episode records how many turns the machine
    actually took.
    """

    name = "capacity-first"
    required_tiers = (SELF_HOSTED, CHEAP)

    def __init__(
        self,
        inflight: Callable[[], int | None],
        *,
        ceiling: int = 48,
        safety: float = 0.7,
        malformed_limit: int = 3,
    ) -> None:
        self.inflight = inflight
        self.ceiling = ceiling
        self.safety = safety
        self.malformed_limit = malformed_limit
        # Kept on the policy, not on the shared episode state: it is this policy's
        # business, and a shared state object that grows a field per policy is how the
        # next policy inherits five that do not apply to it.
        self.withdrawn: str | None = None

    @property
    def admit_below(self) -> float:
        return self.ceiling * self.safety

    def decide(self, state: EpisodeState) -> Decision:
        if self.withdrawn:
            return Decision(CHEAP, self.withdrawn)
        streak = state.malformed_streak(SELF_HOSTED)
        if streak >= self.malformed_limit:
            # This tier is not answering in a usable form. Withdrawing it rescues the
            # episode and flatters the tier, so the reason is recorded on every later step —
            # and it is counted per tier, so the cheap model's mistakes cannot retire the
            # machine and have the log blame the machine.
            self.withdrawn = (
                f"self-hosted withdrawn: {streak} unparseable turns in a row from it by "
                f"step {state.steps}"
            )
            return Decision(CHEAP, self.withdrawn)
        try:
            running = self.inflight()
        except Exception as exc:  # noqa: BLE001 - any failure to read means "do not send"
            return Decision(CHEAP, f"in-flight count unreadable ({type(exc).__name__})")
        if running is None:
            return Decision(CHEAP, "in-flight count unavailable")
        if running >= self.admit_below:
            return Decision(
                CHEAP, f"{running} in flight, at or above the {self.admit_below:.0f} limit"
            )
        return Decision(
            SELF_HOSTED, f"{running} in flight, below the {self.admit_below:.0f} limit"
        )

    def describe(self) -> str:
        return (
            f"{self.name} (ceiling={self.ceiling}, safety={self.safety:.0%}, "
            f"admit below {self.admit_below:.0f})"
        )


class RoleBased(Policy):
    """Route by what the step is for, and pay no switch tax doing it.

    v1 killed *inferred* difficulty. This is not that: the harness knows what each step is
    for because it knows which tool was called, so the label is one we control rather than
    one we predict.

    The mechanism matters as much as the table. A tool whose step type the table assigns
    above the worker is not offered to the worker at all; when the worker is ready it hands
    off, and the premium model receives a fresh request carrying the problem statement and
    the worker's findings rather than the accumulated conversation. That request establishes
    no prefix worth taxing, so unlike escalation it can happen more than once — and after
    the patch lands the worker resumes and can test it, which is what keeps this arm on the
    same footing as the others.
    """

    name = "role-based"
    hands_off_patch = True

    def __init__(self, worker_tier: str = CHEAP, decider_tier: str = PREMIUM) -> None:
        self.worker_tier = worker_tier
        self.decider_tier = decider_tier
        self.required_tiers = (worker_tier, decider_tier)

    @property
    def withholds(self) -> tuple[str, ...]:
        return decider_tools()

    def decide(self, state: EpisodeState) -> Decision:
        return Decision(self.worker_tier, "worker turn")

    def patch_tier(self) -> str:
        return self.decider_tier

    def describe(self) -> str:
        return (
            f"{self.name} (worker={self.worker_tier}, patch={self.patch_tier()}, "
            f"withheld={list(self.withholds)})"
        )


POLICIES = {
    PremiumOnly.name: PremiumOnly,
    CheapOnly.name: CheapOnly,
    SelfHostedOnly.name: SelfHostedOnly,
    OneWayEscalation.name: OneWayEscalation,
    CapacityFirst.name: CapacityFirst,
    RoleBased.name: RoleBased,
}
