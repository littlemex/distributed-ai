#!/usr/bin/env python3
"""One episode: one instance, one policy, inside the official image.

    python loop.py --instance /work/instance.json --policy cheap-then-escalate \
                   --tiers /work/tiers.json --pricing /work/pricing.json --out /work/run

Writes `episode.json` (every step, every billed token, the tier that took it) and
`diff.patch` (what the agent changed). It does not decide whether the episode succeeded —
`score.py` does that afterwards, applying the tests only once this diff has been captured.
Keeping them apart is what guarantees the agent never sees what judges it.

Two things this file is careful about, because both would silently produce a flattering
number:

**Failure is charged.** An episode that runs out of steps, tokens or money is recorded with
everything it spent. The unit v3 reports is cost per *solved* task, so a cheap policy that
gives up early has to carry its own bill.

**An escalation is a real handover.** The conversation moves to the premium model verbatim,
so the switch tax is paid and measured rather than modelled. The role-based policy does the
opposite on purpose: its premium call is a fresh, self-contained request, so there is no
prefix to re-establish. Those are two different mechanisms and the log says which one ran.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import policy as pol  # noqa: E402
import tools  # noqa: E402
import transport  # noqa: E402

SYSTEM = """\
You are fixing a bug in a Python repository checked out at /testbed. You interact with it \
only through the actions below, one per turn, and you are finished when the library behaves \
correctly — a test suite you cannot see will decide that.

{protocol}
Work in this order unless you have a reason not to: find the code the report is about, read \
enough of it to know why it misbehaves, change it, and run any existing tests near it. Do \
not add new files unless the fix needs one.
"""

# The same instructions with the syntax removed, for --protocol function-calling. Everything that
# is not about *how to write a call* is word-for-word identical, so the two arms differ in encoding
# and not in what the model is asked to do.
SYSTEM_TOOL_CALLING = """\
You are fixing a bug in a Python repository checked out at /testbed. You interact with it \
only through the tools provided, one call per turn, and you are finished when the library behaves \
correctly — a test suite you cannot see will decide that.

Rules that are enforced rather than requested:

* Editing a test file fails the task. The tests that judge you are not in this checkout;
  they are applied after you finish, so there is nothing to be gained by guessing at them.
* `old` must appear exactly once in the file, whitespace included. If it does not, the
  edit is refused and you are told so.
* Paths are relative to the checkout.

Work in this order unless you have a reason not to: find the code the report is about, read \
enough of it to know why it misbehaves, change it, and run any existing tests near it. Do \
not add new files unless the fix needs one.
"""

HANDOFF = """\
You are writing the fix for a bug in a Python repository. Another engineer has already \
investigated and hands you their findings. Reply with `write_patch` actions and nothing \
else — as many as the fix needs. You cannot read files or run tests here; what you are \
given below is what there is.

{protocol}
## The report

{problem}

## What the investigation found

{findings}

## The code as it stands

{excerpts}
"""


# What the patch writer is offered. An earlier version handed it the whole protocol —
# every tool, and "one action per turn" — while asking for patches only and silently
# discarding anything else, so a model that obediently opened with a `read_file` produced an
# episode with no patch in it. The offer now matches what is accepted.
PATCH_ONLY_PROTOCOL = tools.protocol(
    withhold=("list_dir", "search", "read_file", "run_tests", "done"),
    # The handoff asks for as many edits as the fix needs, so the protocol it carries must
    # not also say "exactly one action per turn": a two-file fix from an obedient model came
    # back as one file.
    one_per_turn=False,
)


@dataclass
class Step:
    """One turn, with the tier that took it and what it was billed."""

    index: int
    tier: str
    # Why this tier and not another. A capacity-first episode that never reached the GPU
    # and one that filled it look identical without this.
    route_reason: str
    model: str
    step_type: str
    tool: str | None
    signature: str | None
    ok: bool
    tests_passed: bool | None
    # Recorded because "length" means the turn was cut off at the output limit. The first
    # real premium episode ended a patch turn on exactly the cap, so this is not
    # hypothetical: an arm that is being truncated is being measured with a handicap, and
    # the number to change is the cap rather than the conclusion.
    finish_reason: str | None
    latency_ms: float
    ttft_ms: float | None
    prompt_tokens: int
    fresh_prompt_tokens: int
    cached_prompt_tokens: int
    cache_write_tokens: int
    completion_tokens: int
    reasoning_tokens: int
    usd: float
    escalated_here: bool = False
    error: str | None = None
    triggers: list[str] = field(default_factory=list)
    # Non-zero only on the first turn after a handover: what re-establishing the prefix on
    # a model that has never seen it cost, over what the same tokens would have cost warm.
    switch_tax_usd: float = 0.0
    # What abandoned attempts on this step were billed. Retried calls were paid for even
    # though their output was thrown away, and the tiers that break most often are the
    # cheap ones, so dropping this would discount exactly the arm under test.
    retried_usd: float = 0.0
    retried_attempts: int = 0
    # Set when the usage block cannot be priced as reported.
    usage_anomaly: str | None = None
    # Set when the provider never reported usage and the cost is an approximation.
    usd_estimated: bool = False
    # Which serialisations the arguments arrived in, and whether any of them is one the v1 reader
    # would have refused. Recorded per step, not summed per episode, so a solved trajectory can be
    # audited for whether it ever depended on the tolerant path -- see tools.GRAMMAR_VERSION.
    arg_encodings: list[str] = field(default_factory=list)
    tolerant_parse: bool = False
    # How much visible thinking preceded the call, in characters. Recorded because this deployment
    # has no reasoning parser: the box's thinking arrives as ordinary content and is billed as
    # ordinary output tokens, so `reasoning_tokens` is 0 whether thinking is on or off, and a reader
    # comparing this arm against a provider that reports the split would read the 0 as "did not
    # think". The token cost of it is already in completion_tokens.
    thinking_chars: int = 0


def build_policy(name: str, args) -> pol.Policy:
    if name == pol.CapacityFirst.name:
        return pol.CapacityFirst(
            inflight=lambda: vllm_inflight(args.vllm_metrics),
            ceiling=args.capacity_ceiling,
            safety=args.capacity_safety,
        )
    if name == pol.RoleBased.name:
        return pol.RoleBased(worker_tier=args.worker_tier)
    factory = pol.POLICIES.get(name)
    if factory is None:
        raise SystemExit(f"[FAIL] no policy called {name!r}; have {sorted(pol.POLICIES)}")
    return factory()


def vllm_inflight(metrics_url: str | None) -> int | None:
    """How many requests the self-hosted server has in flight right now.

    From the server's own counter rather than from anything this process tracks, because
    the machine is shared and a count kept locally would admit past the ceiling as soon as
    a second episode ran.
    """
    if not metrics_url:
        return None
    with urllib.request.urlopen(metrics_url, timeout=5) as response:
        text = response.read().decode("utf-8", "replace")
    # Matched with or without labels. vLLM emits labels today, but a build that does not
    # would have made every turn spill to the paid tier and turned this policy silently
    # into `cheap-always`.
    def gauge(name: str) -> float | None:
        for line in text.splitlines():
            if line.startswith(name) and line[len(name):len(name) + 1] in ("{", " "):
                try:
                    return float(line.rsplit(" ", 1)[1])
                except ValueError:
                    return None
        return None

    running = gauge("vllm:num_requests_running")
    waiting = gauge("vllm:num_requests_waiting")
    if running is None:
        raise RuntimeError(
            f"{metrics_url} answered but has no vllm:num_requests_running gauge"
        )
    # A waiting request is already past the ceiling, so it counts against admission.
    return int(running + (waiting or 0))


def load_tiers(path: Path, default_url: str) -> pol.Roster:
    """Read which model each tier is, where it lives and what it is charged at."""
    raw = json.loads(path.read_text())

    def model(tier: str) -> pol.Model | None:
        entry = raw.get(tier)
        if not entry:
            return None
        rate, basis = None, entry.get("rate_basis")
        if entry.get("rate"):
            if not basis:
                raise SystemExit(
                    f"[FAIL] the {tier} tier states its own rate but no rate_basis. An "
                    "explicit price has to say where it came from, or the cost column is "
                    "an assertion."
                )
            rate = pol.Rate(key=f"{tier}:stated", **entry["rate"])
        elif not entry.get("pricing_key"):
            raise SystemExit(
                f"[FAIL] the {tier} tier needs either a pricing_key from the gateway's "
                "table or an explicit rate with a rate_basis."
            )
        return pol.Model(
            tier=tier,
            name=entry["model"],
            pricing_key=entry.get("pricing_key"),
            effort=entry.get("reasoning_effort"),
            url=entry.get("url") or default_url,
            api_key_env=entry.get("api_key_env", "STRATOCLAVE_API_KEY"),
            rate=rate,
            rate_basis=basis,
            api=entry.get("api", "chat"),
            template_kwargs=entry.get("chat_template_kwargs"),
        )

    premium, cheap = model(pol.PREMIUM), model(pol.CHEAP)
    if premium is None or cheap is None:
        raise SystemExit("[FAIL] tiers.json must define at least 'premium' and 'cheap'")
    return pol.Roster(premium=premium, cheap=cheap, self_hosted=model(pol.SELF_HOSTED))


def run_episode(args) -> dict:
    instance = json.loads(Path(args.instance).read_text())
    roster = load_tiers(Path(args.tiers), args.url)
    rates = pol.Rate.table(Path(args.pricing))
    strategy = build_policy(args.policy, args)
    # Each policy declares the tiers it can route to, so a missing one is refused now
    # rather than crashing at step thirty with the money already spent.
    for tier in strategy.required_tiers:
        _rate_for(rates, roster.of(tier))
    budget = pol.Budget(
        max_steps=args.max_steps,
        max_tokens=args.max_tokens,
        repeat_k=args.repeat_k,
        max_usd=args.max_usd,
        max_handoffs=args.max_handoffs,
    )
    state = pol.EpisodeState()
    extra = ("handoff",) if strategy.hands_off_patch else ()
    system = (
        SYSTEM_TOOL_CALLING if args.protocol == "function-calling"
        else SYSTEM.format(
            protocol=tools.protocol(withhold=strategy.withholds, add=extra)
        )
    )
    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": _opening(instance)},
    ]

    steps: list[Step] = []
    per_tier: dict[str, dict[str, float]] = {}
    switch_tax_usd = 0.0
    stopped = "the agent finished"
    started = time.time()
    read_paths: list[str] = []

    def charge(step: Step) -> None:
        """The one place a step is added to the totals.

        One place on purpose: an earlier version updated the running spend inside the main
        loop and again by hand in the handoff branch, which is how two accounting paths
        drift apart without either looking wrong.
        """
        state.spend_usd += step.usd + step.retried_usd
        state.tokens_in += step.prompt_tokens
        state.tokens_out += step.completion_tokens
        bucket = per_tier.setdefault(
            step.tier,
            {"calls": 0, "usd": 0.0, "in": 0, "out": 0, "retried_usd": 0.0},
        )
        bucket["calls"] += 1
        bucket["usd"] += step.usd + step.retried_usd
        bucket["retried_usd"] += step.retried_usd
        bucket["in"] += step.prompt_tokens
        bucket["out"] += step.completion_tokens

    episode: dict = {}
    try:
        stopped = _drive(
            args, instance, roster, rates, strategy, budget, state,
            messages, steps, charge, read_paths,
        )
    except Exception as exc:  # noqa: BLE001 - recorded, then re-raised
        stopped = f"the harness failed: {type(exc).__name__}: {exc}"
        raise
    finally:
        # Summed, not first: a mechanism with more than one handover would otherwise report
        # only the cost of its first.
        switch_tax_usd = sum(step.switch_tax_usd for step in steps)
        episode = _write_episode(
            args, instance, roster, strategy, budget, state, steps, per_tier,
            stopped, started, switch_tax_usd, messages,
        )
    return episode


def _drive(
    args, instance, roster, rates, strategy, budget, state,
    messages, steps, charge, read_paths,
) -> str:
    """Take steps until something stops the episode, and return what stopped it.

    Every exit is a `return` with a reason, because "why did this episode end" is a column
    in the results: an arm that runs out of steps and an arm that declared itself finished
    have both failed if the tests fail, but they have failed differently and the difference
    is what says whether the budget was the binding constraint.
    """
    handoffs = 0
    # The share of input each tier last had served from cache, used to apportion an estimate
    # when a stream breaks before its usage chunk. Per tier because the shares differ by an
    # order of magnitude between a long thread and a fresh call.
    cached_share: dict[str, float] = {}
    while True:
        halt = pol.exhausted(state, budget)
        if halt:
            return halt

        decision = strategy.decide(state)
        model = roster.of(decision.tier)
        rate = _rate_for(rates, model)
        try:
            reply = transport.complete(
                _endpoint_for(args, model),
                model=model.name,
                messages=messages,
                max_tokens=args.max_reply_tokens,
                reasoning_effort=model.effort,
                tool_schemas=_schemas_for(args, strategy),
                template_kwargs=model.template_kwargs,
            )
        except transport.Unreachable as exc:
            # The attempts that failed were still billed, so they are charged before the
            # episode ends rather than vanishing from the totals.
            if getattr(exc, "billed", None):
                state.steps += 1
                steps.append(
                    _unreachable_step(state.steps, decision, model, rate, exc)
                )
                charge(steps[-1])
            return f"the {decision.tier} tier could not be reached: {exc}"

        state.steps += 1
        if not reply.priced:
            # A stream that broke before the usage chunk. Approximated rather than left at
            # zero: a free step would also slip past the spend ceiling.
            reply.estimate_usage(
                sum(len(str(m.get("content", ""))) for m in messages),
                cached_share.get(decision.tier),
            )
        elif reply.prompt_tokens:
            cached_share[decision.tier] = reply.cached_prompt_tokens / reply.prompt_tokens
        # From this turn's own usage block: what it paid over what the same input would
        # have cost warm. An upper bound, since a warm model would still have paid fresh for
        # the turn's new material — stated in `switch_tax_usd`.
        tax = (
            pol.switch_tax_usd(
                rate,
                fresh_in=reply.fresh_prompt_tokens,
                cache_write=reply.cache_write_tokens,
            )
            if state.escalated_at == state.steps - 1 and decision.tier == pol.PREMIUM
            else 0.0
        )

        actions = (
            tools.from_tool_calls(reply.tool_calls)
            if args.protocol == "function-calling"
            else tools.parse_all(reply.text or "")
        )
        action, observation = _act(
            actions, strategy, state, read_paths, reply, decision.tier
        )
        state.last_tests_passed = observation.tests_passed
        if observation.tests_passed is False:
            state.verify_failures += 1

        if args.protocol == "function-calling" and reply.tool_calls:
            calls = [
                {"id": call["id"] or f"call_{state.steps}_{i}", "type": "function",
                 "function": {"name": call["name"], "arguments": call["arguments"]}}
                for i, call in enumerate(reply.tool_calls)
            ]
            # A thinking tier's own reasoning is not fed back. This deployment has no reasoning
            # parser, so the thinking arrives as ordinary content, and echoing it would put the
            # model's scratch work in every later prompt -- which the Responses arm does not do for
            # gpt-5.6-terra either. Keeping the two arms symmetric is the whole point of the knob.
            thinks = bool((model.template_kwargs or {}).get("enable_thinking"))
            messages.append({
                "role": "assistant",
                "content": None if thinks else (reply.text or None),
                "tool_calls": calls,
            })
            # One result per call, because a provider that sent two calls expects two results and
            # rejects the next request otherwise.
            text = _observation_text(observation)
            for call in calls:
                messages.append({
                    "role": "tool", "tool_call_id": call["id"], "content": text,
                })
                text = "(carried out together with the call above)"
        else:
            messages.append({"role": "assistant", "content": reply.text or ""})
            messages.append({"role": "user", "content": _observation_text(observation)})

        reasons = strategy.consider(state, budget)
        step = _step(
            state.steps, decision, model, rate, action, observation, reply, reasons, tax
        )
        steps.append(step)
        charge(step)
        print(
            f"[{state.steps:>3}] {decision.tier:<11} {step.step_type:<9} "
            f"{(action.tool if action else 'malformed'):<12} "
            f"${state.spend_usd:.3f} {'ESCALATED' if reasons else ''}",
            flush=True,
        )

        # Only as the last action of the turn: a `done` with work after it is not a finish,
        # and an illustrated one in the middle of a plan is not either.
        if actions and actions[-1].tool == "done":
            if state.has_patched:
                return "the agent said it was finished"
            # A turn that declared itself finished having changed nothing. The cheap tier
            # did exactly this on its first turn, alongside an edit that was refused, and
            # the episode ended in one step with an empty diff — which reads as a model
            # that cannot fix the bug rather than one that was not asked again.
            messages.append(
                {
                    "role": "user",
                    "content": (
                        "Nothing has been changed yet, so the bug is still there. Use "
                        "`write_patch` to change the library, then say `done`."
                        if "write_patch" not in strategy.withholds
                        else "Nothing has been changed yet. Hand off so the fix can be "
                        "written, then say `done`."
                    ),
                }
            )
            continue

        if actions and actions[-1].tool == "handoff" and strategy.hands_off_patch:
            if handoffs >= budget.max_handoffs:
                messages.append(
                    {
                        "role": "user",
                        "content": (
                            f"You have handed off {handoffs} times, which is the limit. "
                            "Test what is there and finish with `done`."
                        ),
                    }
                )
                continue
            # Checked here as well as at the top of the loop: a handoff is the most
            # expensive call in the episode, and letting it through after the ceiling was
            # reached would give this policy a budget the others do not have.
            halt = pol.exhausted(state, budget)
            if halt:
                return f"{halt} before the patch could be handed off"
            handoffs += 1
            state.steps += 1
            patch_step, outcome = _write_the_patch(
                args, roster, rates, strategy, instance,
                observation.text, read_paths, state.steps,
            )
            steps.append(patch_step)
            charge(patch_step)
            print(f"      {outcome} — ${state.spend_usd:.3f}", flush=True)
            # The worker resumes rather than the episode ending here. Otherwise this arm is
            # the only one that cannot test its own patch, which would make it the only arm
            # judged on an untested fix.
            messages.append(
                {
                    "role": "user",
                    "content": (
                        f"The fix was written and applied: {outcome}. Run the tests you "
                        "think are relevant, fix anything that is still wrong by handing "
                        "off again, and call `done` when the library behaves."
                    ),
                }
            )


def _act(
    actions: list[tools.Action],
    strategy: pol.Policy,
    state: pol.EpisodeState,
    read_paths: list[str],
    reply: transport.Reply,
    tier: str,
) -> tuple[tools.Action | None, tools.Observation]:
    """Carry out everything the turn asked for, and say what the turn was.

    All of it, in order. The rule is one action per turn, but a model that breaks the rule
    has still done work that was paid for in this one call, and executing only part of it
    scores the model on the harness's bookkeeping — the first real run had a premium model
    send its patch and its `done` together, and only the `done` was carried out.

    An illustrated example being executed alongside the real call is the risk this trades
    for, and it is a small one: a made-up `write_patch` fails the exact-match rule and is
    reported, and a read of an invented path is harmless.
    """
    if not actions:
        # Why there was no action decides whose fault it was, and the capacity-first policy
        # withdraws a tier on this count — so a broken connection or an answer cut off at
        # the token limit must not be filed as the model failing to follow a format.
        if reply.error:
            state.transport_failures += 1
            return None, tools.Observation(
                f"The last call did not complete ({reply.error}). Nothing was carried out; "
                "send the action again.",
                ok=False,
            )
        if reply.finish_reason == "length":
            state.transport_failures += 1
            return None, tools.Observation(
                "Your reply was cut off at the output limit before the action was complete. "
                "Answer more briefly: one action, and keep the reasoning short.",
                ok=False,
            )
        state.note_malformed(tier)
        return None, tools.Observation(
            'No action found. Reply with exactly one <action tool="..."> block.',
            ok=False,
        )
    state.clear_malformed(tier)
    principal = tools.principal(actions)
    state.signatures.append(
        principal.signature if len(actions) == 1
        else " + ".join(a.signature for a in actions)
    )
    parts, ok, tests_passed = [], True, None
    for action in actions:
        if action.tool in strategy.withholds:
            parts.append(
                f"{action.tool} is not available to you. When you know what the fix is, "
                "call handoff with a note describing it and the files it touches."
            )
            ok = False
            continue
        result = tools.execute(action)
        # Only a read that actually succeeded. Recording the requested path regardless meant
        # a refused read of a path outside the checkout still went into the handoff
        # excerpts, where it would have been posted to a model.
        if action.tool == "read_file" and result.ok and action.args.get("path"):
            read_paths.append(action.args["path"])
        if action.tool == "write_patch" and result.ok:
            # From here a failing test is a disagreement with the agent's work rather than
            # the bug that was reported, which is what the first trigger means.
            state.has_patched = True
        ok = ok and result.ok
        if result.tests_passed is not None:
            tests_passed = result.tests_passed
        # Per-action labelling only when there is more than one: for a single action the
        # caller adds the refusal marker, and two of them read as a harness stutter.
        if len(actions) == 1:
            parts.append(result.text)
        else:
            marker = "" if result.ok else "[refused] "
            parts.append(f"[{action.tool}] {marker}{result.text}")
    return principal, tools.Observation(
        "\n\n".join(parts), ok=ok, tests_passed=tests_passed
    )


def _step(
    index: int,
    decision: pol.Decision,
    model: pol.Model,
    rate: pol.Rate,
    action: tools.Action | None,
    observation: tools.Observation,
    reply: transport.Reply,
    reasons: tuple[str, ...],
    tax: float,
) -> Step:
    """One turn as a row, priced from what the provider said it billed."""
    return Step(
        index=index,
        tier=decision.tier,
        route_reason=decision.reason,
        model=model.name,
        step_type=action.step_type if action else "malformed",
        tool=action.tool if action else None,
        signature=action.signature if action else None,
        ok=observation.ok,
        tests_passed=observation.tests_passed,
        finish_reason=reply.finish_reason,
        latency_ms=reply.latency_ms,
        ttft_ms=reply.ttft_ms,
        prompt_tokens=reply.prompt_tokens,
        fresh_prompt_tokens=reply.fresh_prompt_tokens,
        cached_prompt_tokens=reply.cached_prompt_tokens,
        cache_write_tokens=reply.cache_write_tokens,
        completion_tokens=reply.completion_tokens,
        reasoning_tokens=reply.reasoning_tokens,
        usd=_reply_cost(rate, reply),
        escalated_here=bool(reasons),
        error=reply.error,
        triggers=list(reasons),
        switch_tax_usd=tax,
        retried_usd=sum(
            pol.call_cost(rate, **{k: v for k, v in a.items() if k != "error"})
            for a in reply.abandoned
        ),
        retried_attempts=len(reply.abandoned),
        usage_anomaly=reply.usage_anomaly,
        usd_estimated=reply.estimated,
        arg_encodings=list(action.encodings) if action else [],
        tolerant_parse=bool(action and action.tolerant),
        # Only when the turn also produced a call: a reply that is nothing but prose is a
        # no-action step and its length is not thinking, it is the failure.
        thinking_chars=len(reply.text or "") if (reply.tool_calls and reply.text) else 0,
    )


def _unreachable_step(
    index: int, decision: pol.Decision, model: pol.Model, rate: pol.Rate,
    exc: transport.Unreachable,
) -> Step:
    """A turn that never produced an answer but was billed for trying."""
    billed = getattr(exc, "billed", [])
    return Step(
        index=index,
        tier=decision.tier,
        route_reason=decision.reason,
        model=model.name,
        step_type="unreachable",
        tool=None,
        signature=None,
        ok=False,
        tests_passed=None,
        finish_reason=None,
        latency_ms=0.0,
        ttft_ms=None,
        prompt_tokens=sum(b["fresh_in"] + b["cache_read"] + b["cache_write"] for b in billed),
        fresh_prompt_tokens=sum(b["fresh_in"] for b in billed),
        cached_prompt_tokens=sum(b["cache_read"] for b in billed),
        cache_write_tokens=sum(b["cache_write"] for b in billed),
        completion_tokens=sum(b["out"] for b in billed),
        reasoning_tokens=0,
        usd=0.0,
        retried_usd=sum(
            pol.call_cost(rate, **{k: v for k, v in b.items() if k != "error"})
            for b in billed
        ),
        retried_attempts=len(billed),
        usd_estimated=True,
        error=str(exc)[:500],
    )


def _reply_cost(rate: pol.Rate, reply: transport.Reply) -> float:
    return pol.call_cost(
        rate,
        fresh_in=reply.fresh_prompt_tokens,
        cache_read=reply.cached_prompt_tokens,
        cache_write=reply.cache_write_tokens,
        out=reply.completion_tokens,
    )


def _write_episode(
    args, instance, roster, strategy, budget, state, steps, per_tier,
    stopped, started, switch_tax_usd, messages,
) -> dict:
    """Record the episode, including one that ended badly.

    In a `finally`, because the tokens were billed whatever happened next. An episode that
    crashed after twenty paid steps and left no file is money spent on nothing, and worse,
    it is money missing from the totals the comparison is made on.
    """
    diff = tools.current_diff()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "diff.patch").write_text(diff)
    # The replies themselves, so a grammar change can be re-parsed against what was actually sent
    # instead of re-run. Without this the only record of a turn's syntax was its signature, which
    # is why the 2228 already-paid-for steps could not be re-read under the v2 reader and the
    # non-interference check had to be inferred. Assistant turns in full because they are the thing
    # being parsed; observations clipped because they are the harness's own output and large.
    (out / "transcript.json").write_text(json.dumps([
        m if m.get("role") == "assistant" else {**m, "content": (m.get("content") or "")[:500]}
        for m in messages
    ], indent=1))
    episode = {
        "instance_id": instance["instance_id"],
        "policy": strategy.describe(),
        "tiers": {
            tier: asdict(roster.of(tier))
            for tier in (pol.PREMIUM, pol.CHEAP, pol.SELF_HOSTED)
            if tier != pol.SELF_HOSTED or roster.self_hosted
        },
        "budget": asdict(budget),
        "stopped_because": stopped,
        "wall_s": time.time() - started,
        "steps": [asdict(step) for step in steps],
        "totals": {
            "steps": state.steps,
            "usd": state.spend_usd,
            "prompt_tokens": state.tokens_in,
            "completion_tokens": state.tokens_out,
            "verify_failures": state.verify_failures,
            "diff_bytes": len(diff),
        },
        "format_compliance": _format_compliance(steps, getattr(args, "protocol", "text")),
        "per_tier": per_tier,
        "escalated_at": state.escalated_at,
        "triggers_fired": state.triggers_fired,
        "switch_tax_usd": switch_tax_usd,
        "step_types": _step_type_shares(steps),
        **_comparability(strategy, budget, state, steps, stopped),
    }
    (out / "episode.json").write_text(json.dumps(episode, indent=2))
    print(
        f"\n[OK] {instance['instance_id']} {strategy.name}: {state.steps} steps, "
        f"${state.spend_usd:.3f}, {len(diff)} bytes of diff — {stopped}"
    )
    if switch_tax_usd:
        print(f"     switch tax on the handover: ${switch_tax_usd:.3f}")
    if not episode["comparable"]:
        print(f"     [WARNING] not comparable: {episode['not_comparable_because']}")
    for note in episode["notes"]:
        print(f"     [NOTE] {note}")
    return episode


def _format_compliance(steps: list[Step], protocol: str = "text") -> dict:
    """Whether the model could drive the tools at all, kept apart from whether it fixed the bug.

    A single solve rate confounds the two, and this project has now seen the confound dominate: a
    box that named the right tool on every turn scored zero because it wrote the arguments in its
    own dialect. So each failure mode is counted separately, and the tolerant-path count is
    reported whether or not it is zero -- a reader comparing tiers needs to see that it is 0% for
    the APIs and large for one box, because that asymmetry is the finding.
    """
    needs_arg = {"list_dir": "dir", "search": "pattern", "read_file": "path",
                 "run_tests": "target", "write_patch": "path"}
    counted = [s for s in steps if s.step_type != "unreachable"]
    parsed = [s for s in counted if s.tool]
    return {
        "grammar_version": tools.GRAMMAR_VERSION,
        "protocol": protocol,
        "steps": len(counted),
        "no_action": sum(1 for s in counted if not s.tool),
        "unknown_tool": sum(1 for s in parsed if s.tool not in tools.STEP_TYPE),
        # The signature is built from the naming arguments only, so empty parentheses on a tool
        # that has one means the target was never named -- but only the refused ones are failures.
        # `list_dir` with no `dir` lists the checkout root and succeeds, and counting that as a
        # malformed action inflates the very number this block exists to keep honest.
        "empty_required_arg": sum(
            1 for s in parsed
            if s.tool in needs_arg and (s.signature or "").endswith("()") and not s.ok
        ),
        "tolerant_parse": sum(1 for s in parsed if s.tolerant_parse),
        "encodings": sorted({e for s in parsed for e in s.arg_encodings}),
    }


def _schemas_for(args, strategy: pol.Policy) -> list[dict] | None:
    """The tool schemas this arm declares, or nothing when the protocol is text."""
    if args.protocol != "function-calling":
        return None
    return tools.schemas(
        withhold=strategy.withholds,
        add=("handoff",) if strategy.hands_off_patch else (),
    )


def _comparability(
    strategy: pol.Policy,
    budget: pol.Budget,
    state: pol.EpisodeState,
    steps: list[Step],
    stopped: str,
) -> dict:
    """Whether this episode may be counted in the paired comparison, and what to watch.

    Two things must not be quietly folded into a success rate.

    The dollar ceiling binds the premium baseline first, by construction, so an episode cut
    off by it is not evidence about quality — it is evidence about the ceiling. It is
    excluded and counted, which `docs/V3-PLAN.md` pre-registers, rather than being reported
    as a failure that happens to favour the cheap arm.

    And a capacity-first episode that never reached the self-hosted machine is a
    `cheap-always` measurement wearing another name. That is not a reason to drop it, but
    reporting it without saying so would be.
    """
    notes: list[str] = []
    reasons = {step.route_reason for step in steps}
    if pol.SELF_HOSTED in strategy.required_tiers:
        used = sum(1 for step in steps if step.tier == pol.SELF_HOSTED)
        if used == 0:
            notes.append(
                "no step reached the self-hosted tier, so this is a cheap-tier measurement "
                f"under another name. Routing reasons seen: {sorted(reasons)}"
            )
        else:
            notes.append(f"{used} of {len(steps)} steps ran on the self-hosted tier")
    if any(step.usage_anomaly for step in steps):
        notes.append(next(s.usage_anomaly for s in steps if s.usage_anomaly))
    retried = sum(step.retried_attempts for step in steps)
    if retried:
        spent = sum(step.retried_usd for step in steps)
        notes.append(f"{retried} abandoned attempts were billed ${spent:.3f}")
    estimated = [step for step in steps if step.usd_estimated]
    if estimated:
        notes.append(
            f"{len(estimated)} steps had no usage block and were priced by approximation "
            f"(${sum(s.usd for s in estimated):.3f} of the total)"
        )
    truncated = [s for s in steps if s.finish_reason == "length"]
    if truncated:
        notes.append(
            f"{len(truncated)} of {len(steps)} turns were cut off at the output limit "
            f"(steps {[s.index for s in truncated]}); raise --max-reply-tokens before "
            "reading this arm's quality"
        )
    if state.transport_failures:
        notes.append(
            f"{state.transport_failures} turns produced no action because the call itself "
            "failed or was cut off, which is not the model failing to follow the format"
        )
    ceiling_bound = state.spend_usd >= budget.max_usd
    # The provider, not the policy, decided how this episode went. Three shapes of it, each
    # of which would otherwise be read as a model that could not fix the bug:
    unreachable = "could not be reached" in stopped
    mostly_failed_calls = state.transport_failures * 3 > max(len(steps), 1)
    approximated = sum(step.usd for step in steps if step.usd_estimated)
    mostly_guessed = approximated > 0.25 * max(state.spend_usd, 1e-9)
    excluded_because = (
        f"the ${budget.max_usd:.2f} runaway ceiling bound this episode, which binds the "
        "premium baseline first and so cannot be read as a quality result"
        if ceiling_bound
        else f"the episode ended on the transport rather than on the policy: {stopped}"
        if unreachable
        else f"{state.transport_failures} of {len(steps)} turns produced no action because "
        "the call failed, so what this arm would have done is not observed"
        if mostly_failed_calls
        else f"${approximated:.3f} of ${state.spend_usd:.3f} was priced by approximation "
        "rather than reported, which is too much of the bill to compare"
        if mostly_guessed
        else None
    )
    return {
        "comparable": excluded_because is None,
        "not_comparable_because": excluded_because,
        "binding_constraint": (
            "spend" if ceiling_bound
            else "steps" if state.steps >= budget.max_steps
            else "tokens" if state.tokens_in + state.tokens_out >= budget.max_tokens
            else "the agent decided"
        ),
        "notes": notes,
    }


def _step_type_shares(steps: list[Step]) -> dict[str, dict[str, float]]:
    """How much of the episode each kind of step was, in turns and in money.

    This is the quantity that bounds what role-based and capacity-first routing can save,
    and it is worth reporting even from a run where neither was used: if searching and
    reading are a tenth of the bill, moving them to a cheap tier cannot save much whatever
    the quality turns out to be.
    """
    shares: dict[str, dict[str, float]] = {}
    for step in steps:
        bucket = shares.setdefault(step.step_type, {"steps": 0, "usd": 0.0})
        bucket["steps"] += 1
        bucket["usd"] += step.usd
    return shares


def _opening(instance: dict) -> str:
    return (
        f"Repository: {instance['repo']} at /testbed\n\n"
        f"## The report\n\n{instance['problem_statement']}\n\n"
        "Begin."
    )


def _observation_text(observation: tools.Observation) -> str:
    prefix = "" if observation.ok else "[refused] "
    if observation.tests_passed is True:
        prefix = "[tests passed] "
    elif observation.tests_passed is False:
        prefix = "[tests failed] "
    return f"{prefix}{observation.text or '(no output)'}"


def _write_the_patch(
    args,
    roster: pol.Roster,
    rates: dict[str, pol.Rate],
    strategy: pol.RoleBased,
    instance: dict,
    findings: str,
    read_paths: list[str],
    index: int,
) -> tuple[Step, str]:
    """The role-based policy's decisive step: a fresh premium call, so no tax is paid.

    It is given the report, the worker's findings and the regions the worker read — not the
    conversation. That is the whole economic difference from escalation, and it is why this
    mechanism has no one-way constraint.
    """
    tier = strategy.patch_tier()
    model = roster.of(tier)
    rate = _rate_for(rates, model)
    excerpts = _excerpts(read_paths)
    request = HANDOFF.format(
        protocol=PATCH_ONLY_PROTOCOL,
        problem=instance["problem_statement"],
        findings=findings or "(the worker left no note)",
        excerpts=excerpts or "(the worker read nothing)",
    )
    try:
        reply = transport.complete(
            _endpoint_for(args, model),
            model=model.name,
            messages=[{"role": "user", "content": request}],
            max_tokens=args.max_reply_tokens,
            reasoning_effort=model.effort,
        )
    except transport.Unreachable as exc:
        # Caught here rather than escaping as a harness failure: the patch call is one call
        # on one tier, and losing the episode to it should read as the tier being
        # unreachable, exactly as it does on the main thread.
        return (
            Step(
                index=index, tier=tier,
                route_reason=f"the role table puts a patch on the {tier} tier",
                model=model.name, step_type="patch", tool="write_patch",
                signature="handoff(unreachable)", ok=False, tests_passed=None,
                finish_reason=None, latency_ms=0.0, ttft_ms=None, prompt_tokens=0, fresh_prompt_tokens=0,
                cached_prompt_tokens=0, cache_write_tokens=0, completion_tokens=0,
                reasoning_tokens=0, usd=0.0, error=str(exc),
            ),
            f"the {tier} tier could not be reached for the patch",
        )
    if not reply.priced:
        reply.estimate_usage(len(request))
    applied, refused = 0, 0
    for action in tools.parse_all(reply.text or ""):
        if action.tool != "write_patch":
            continue
        result = tools.execute(action)
        applied += int(result.ok)
        refused += int(not result.ok)
        print(f"      patch {action.args.get('path')}: {'applied' if result.ok else result.text[:80]}")
    return (
        Step(
            index=index,
            tier=tier,
            route_reason=f"the role table puts a patch on the {tier} tier",
            model=model.name,
            step_type="patch",
            tool="write_patch",
            signature=f"handoff({applied} applied)",
            ok=applied > 0,
            tests_passed=None,
            finish_reason=reply.finish_reason,
            latency_ms=reply.latency_ms,
            ttft_ms=reply.ttft_ms,
            prompt_tokens=reply.prompt_tokens,
            fresh_prompt_tokens=reply.fresh_prompt_tokens,
            cached_prompt_tokens=reply.cached_prompt_tokens,
            cache_write_tokens=reply.cache_write_tokens,
            completion_tokens=reply.completion_tokens,
            reasoning_tokens=reply.reasoning_tokens,
            usd=_reply_cost(rate, reply),
            retried_usd=sum(
                pol.call_cost(rate, **{k: v for k, v in a.items() if k != "error"})
                for a in reply.abandoned
            ),
            retried_attempts=len(reply.abandoned),
            usage_anomaly=reply.usage_anomaly,
            usd_estimated=reply.estimated,
            error=reply.error,
        ),
        f"{applied} edits applied, {refused} refused",
    )


def _excerpts(read_paths: list[str], limit: int = 3) -> str:
    """The files the worker looked at, most recent first, whole but capped.

    The handoff has to carry enough for a patch to be written blind. Sending the files
    rather than the conversation is the point: it is a bounded amount of context that does
    not grow with the length of the investigation.
    """
    seen, out = set(), []
    for path in reversed(read_paths):
        if path in seen or len(seen) >= limit:
            continue
        seen.add(path)
        try:
            body = tools.read_within(path)
        except (OSError, ValueError):
            # ValueError is a path outside the checkout. It cannot arrive here now that a
            # refused read is not recorded, and it is still refused here: this is the one
            # place a file leaves the container, and the instance data — tests and
            # reference patch — is mounted just outside it.
            continue
        out.append(f"### {path}\n\n```python\n{body}\n```")
    return "\n\n".join(out)


def _rate_for(rates: dict[str, pol.Rate], model: pol.Model) -> pol.Rate:
    """What this tier is charged at: its stated rate, or the gateway's table."""
    if model.rate is not None:
        return model.rate
    if model.pricing_key not in rates:
        raise SystemExit(
            f"[FAIL] the rate table has no {model.pricing_key!r}; it has {sorted(rates)}. "
            "An unpriced call is an unmeasurable episode."
        )
    return rates[model.pricing_key]


def _endpoint_for(args, model: pol.Model) -> transport.Endpoint:
    """Where to send this tier's calls.

    Per tier, because the paid models are behind the gateway and the self-hosted one is an
    in-cluster server that has never heard of a gateway alias.
    """
    key = os.environ.get(model.api_key_env or "") if model.api_key_env else None
    return transport.Endpoint(
        url=model.url or args.url,
        api_key=key,
        first_event_s=args.first_event_s,
        idle_s=args.idle_s,
        api=model.api,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--instance", required=True)
    parser.add_argument("--tiers", required=True, help="which model each tier is")
    parser.add_argument("--pricing", required=True, help="the gateway's pricing.json")
    parser.add_argument("--policy", default=pol.OneWayEscalation.name,
                        choices=sorted(pol.POLICIES))
    parser.add_argument("--url", default=os.environ.get("ROUTER_URL")
                        or "http://127.0.0.1:8801/v1/chat/completions")
    parser.add_argument("--out", default="/work/run")
    # Defaults taken from `Budget`, so the recorded budget and the flag cannot disagree.
    defaults = pol.Budget()
    parser.add_argument("--max-steps", type=int, default=defaults.max_steps)
    parser.add_argument("--max-tokens", type=int, default=defaults.max_tokens)
    parser.add_argument("--max-usd", type=float, default=defaults.max_usd,
                        help="a runaway guard, not an experimental condition: an episode "
                             "that hits it is recorded as not comparable")
    parser.add_argument("--max-reply-tokens", type=int, default=8192)
    # The text protocol is the benchmark. Function calling is a diagnostic arm: it answers how much
    # of a model's failure to drive the tools is the text protocol resembling, without matching, the
    # tool-call syntax the model was trained on. Episodes from the two are not comparable to each
    # other and the episode records which one produced it.
    parser.add_argument("--protocol", default="text",
                        choices=("text", "function-calling"),
                        help="how the model is asked for a tool call")
    parser.add_argument("--first-event-s", type=float, default=900.0,
                        help="how long a model may think before saying anything")
    parser.add_argument("--idle-s", type=float, default=120.0,
                        help="how long a started stream may go silent")
    parser.add_argument("--repeat-k", type=int, default=defaults.repeat_k)
    parser.add_argument("--max-handoffs", type=int, default=defaults.max_handoffs)
    parser.add_argument("--worker-tier", default=pol.CHEAP,
                        choices=[pol.CHEAP, pol.SELF_HOSTED])
    parser.add_argument("--vllm-metrics", default=os.environ.get("VLLM_METRICS_URL"))
    parser.add_argument("--capacity-ceiling", type=int, default=48,
                        help="measured knee; see docs/V3-PLAN.md")
    parser.add_argument("--capacity-safety", type=float, default=0.7)
    args = parser.parse_args(argv)
    run_episode(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
