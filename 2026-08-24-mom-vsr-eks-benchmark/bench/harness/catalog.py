"""Who is in the pool, and what a call to each member costs.

The harness does not keep its own copy of the roster or the rate table. It asks
the config builder, which is the same code that told the router. A second copy
would let the cost this reports drift from the cost the router scored on, and a
drift like that is invisible in the output — the numbers would simply be wrong
and still look plausible.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

VSR_DIR = Path(__file__).resolve().parents[2] / "vsr"
if str(VSR_DIR) not in sys.path:
    sys.path.insert(0, str(VSR_DIR))

import build_config  # noqa: E402  (path is set above on purpose)

ConfigError = build_config.ConfigError
TOKENS_PER_MILLION = 1_000_000


@dataclass(frozen=True)
class Member:
    """One pool member, as the router sees it."""

    name: str
    alias: str
    transport: str
    pricing_key: str
    prompt_per_1m: float
    completion_per_1m: float
    roles: tuple[str, ...]
    region: str
    priced_as_measured: bool
    # Declared in the pool for members whose serving parameters we control. The
    # harness must not drive a member past it, or its queue is recorded as the
    # model's latency. None means the member has no limit we know of.
    max_concurrent_sequences: int | None

    def cost_usd(self, prompt_tokens: int, completion_tokens: int) -> float:
        """What the gateway's rate table charges for this call.

        This is the rate table's answer, not the ledger's. They agree for a
        successful call; where a run needs the ledger to be the source of record
        (a partial charge, a retry that was billed) the reconciliation step
        replaces this.
        """
        return (
            prompt_tokens * self.prompt_per_1m + completion_tokens * self.completion_per_1m
        ) / TOKENS_PER_MILLION


# Bedrock publishes no list price for these tiers, so the gateway's rate table
# deliberately charges them at the top tier. Cost-aware routing therefore avoids
# them for a reason that is about the rate table and not about the model, and any
# cost claim that includes them has to say so.
OVERCHARGED_PRICING_KEYS = frozenset({"gemma", "nemotron", "qwen3"})


def load_pool(pool_path: Path, stratoclave_defaults: Path) -> list[Member]:
    """Resolve the pool into members with prices, without needing addresses."""
    pool = build_config.load_yaml(pool_path)
    registry = build_config.load_json(stratoclave_defaults / "models.json")
    pricing = build_config.load_json(stratoclave_defaults / "pricing.json")
    resolved = build_config.resolve_members(
        pool,
        build_config.index_registry(registry),
        pricing["rates"],
        addresses=False,
    )
    return [
        Member(
            name=entry["name"],
            alias=entry["alias"],
            transport=entry["transport"],
            pricing_key=entry["pricing_key"],
            prompt_per_1m=entry["pricing"]["prompt_per_1m"],
            completion_per_1m=entry["pricing"]["completion_per_1m"],
            roles=tuple(entry["roles"]),
            region=entry["region"],
            priced_as_measured=entry["pricing_key"] not in OVERCHARGED_PRICING_KEYS,
            max_concurrent_sequences=entry["facts"].get("max_concurrent_sequences"),
        )
        for entry in resolved
    ]


# Sent as no `reasoning_effort` field at all: the only setting every member in this
# pool accepts, and the one v1 measured. Kept as a named level so an arm list always
# contains the v1 comparison point.
DEFAULT_EFFORT = "default"


@dataclass(frozen=True)
class Arm:
    """A member at one reasoning effort: the unit the frontier is drawn over.

    v1 treated a member as an arm and found that routing between members bought no
    accuracy. But the effort dial moves accuracy, cost and latency together within a
    single member, and a frontier drawn without it is missing the deployable
    alternatives it should be compared against — which makes any routing win look
    larger than it is. So the arm is the pair.

    Effort levels are never compared across providers as levels: there is no shared
    unit between GPT's "low" and Grok's "minimal". Only the measured points are
    compared, and a point in a cost-accuracy plane carries no semantics.
    """

    member: Member
    effort: str

    @property
    def name(self) -> str:
        return self.member.name if self.effort == DEFAULT_EFFORT else f"{self.member.name}@{self.effort}"

    @property
    def request_effort(self) -> str | None:
        """What to put in the request body, or None to omit the field."""
        return None if self.effort == DEFAULT_EFFORT else self.effort


def arms(pool_path: Path, members: list[Member]) -> list[Arm]:
    """Expand members into arms using the effort levels the pool declares.

    A member with no entry gets the default level only, so adding a member never
    silently multiplies the run.

    The reverse mistake is the expensive one and is refused rather than defaulted: a
    declaration whose key matches no member in the pool means a member was renamed or
    removed and its effort levels were left behind, and the run would then be paid for
    without the axis it exists to measure. Silently multiplying a run wastes money;
    silently shrinking one wastes the whole run.
    """
    pool = build_config.load_yaml(pool_path)
    declared = pool.get("effort_levels") or {}
    fallback = declared.get(DEFAULT_EFFORT, [DEFAULT_EFFORT])
    # Checked against the pool file's own roster rather than the members passed in,
    # so that analysing a subset of the pool is not mistaken for a stale declaration.
    roster = pool.get("members") or []
    known = {
        entry.get("alias") if isinstance(entry, dict) else entry for entry in roster
    }
    if declared and not known:
        raise ConfigError(
            f"{pool_path}: effort_levels is declared but the member roster could not be "
            "read, so a declaration cannot be matched to a member. Every arm would be "
            "measured at the default level."
        )
    orphans = sorted(set(declared) - known - {DEFAULT_EFFORT})
    if orphans:
        raise ConfigError(
            f"{pool_path}: effort_levels declares {orphans}, which match no member "
            "declared in this pool file. Either the member is gone and the declaration "
            "should be too, or it was renamed and this run would be measured at the "
            "default level only."
        )
    out = []
    for member in members:
        levels = declared.get(member.alias, fallback)
        seen = set()
        for level in levels:
            if level in seen:
                continue
            seen.add(level)
            out.append(Arm(member=member, effort=level))
    return out


def only(members: list[Member], aliases: list[str] | None) -> list[Member]:
    """Narrow the pool to named members, refusing a name that is not in it.

    A pilot measures one thing about a few members and should not pay for the rest, but
    a silently ignored alias would produce a run that looks right and answers a
    different question — so a name that matches nothing is an error rather than a
    filter that quietly returns everyone.
    """
    if not aliases:
        return members
    wanted = set(aliases)
    kept = [m for m in members if m.alias in wanted or m.name in wanted]
    missing = wanted - {m.alias for m in kept} - {m.name for m in kept}
    if missing:
        raise ConfigError(
            f"no member of this pool is called {sorted(missing)}; the pool has "
            f"{sorted(m.alias for m in members)}"
        )
    return kept


def worst_case_usd(
    arms: list[Arm], questions: int, max_tokens: int, prompt_tokens: int = 400
) -> dict[str, float]:
    """What this run costs if every arm spends its whole completion budget.

    The claim that a completion cap is free holds only if raising it does not change
    what the model does, and for a reasoning arm it demonstrably can: the probe that
    justified raising the cap is an arm that used all 2,048 tokens and then all 4,096.
    So the budget is an intervention with a price, and the price is worth seeing before
    the run rather than in a bill afterwards. This is the ceiling, not an estimate —
    the arms that stop early pay far less — and the prompt length is a stated
    assumption because it is not known until the questions are rendered.
    """
    per_arm = {
        arm.name: arm.member.cost_usd(prompt_tokens, max_tokens) * questions
        for arm in arms
    }
    return {"total": sum(per_arm.values()), **per_arm}


def domains(pool_path: Path) -> list[str]:
    """The classifier labels the router is configured to route on."""
    return list(build_config.load_yaml(pool_path)["domains"])


def by_name(members: list[Member]) -> dict[str, Member]:
    return {member.name: member for member in members}
