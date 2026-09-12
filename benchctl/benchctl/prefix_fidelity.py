"""Does a layer still obey turn 1, and still read its own prefix, once the prefix is served from cache?

The routing rule this project arrived at says to send prefill-heavy prefix-reusing traffic to the box above
about 8,000 requests an hour. That is entirely a cost argument, and the family it applies to is the one family
with **no quality number at all**. Recommending traffic to a layer on price while never checking what it
produces there is the gap worth closing next, and it is the gap both advisors named.

## What to measure, without a judge

The interesting failure is specific. A conversation's later turns are 90%+ cache reads, and the two things that
could quietly break are:

* **Instruction retention.** Turn 1 sets a rule. Does turn 6 still follow it, when almost none of turn 6's
  prompt was recomputed?
* **Prefix retrieval.** The shared preamble carries facts. Can the model still find one when asked at turn 5,
  or has the prefix become something it reads past rather than reads?

Both are mechanically checkable, which is the point — this family deliberately has no LLM judge, for the same
reason as the others: a judge is a model whose failures correlate with the models under test.

So each turn asks for one planted fact and requires it in a fixed format:

    TAG: <the build token for module {m}>

A turn passes only if the tag line is present **and** carries the right token. Format and content are recorded
separately, because they fail for different reasons and the difference is diagnostic: a layer that stops
emitting the tag has forgotten the instruction, and one that emits the tag with the wrong token has stopped
reading the preamble.

## The controls, before any layer is scored

The last time this project shipped a scorer without controls it ranked an extract of a document above the human
summary, so the thresholds here are pinned first and the same script prints them:

* **ceiling** — a scripted reply that follows the rule exactly. Must pass 1.00, or the scorer is broken.
* **negative, no tag** — a fluent reply that never emits the line. Must score 0.00.
* **negative, wrong token** — the tag with a plausible but wrong value. Must score 0.00 on content while
  passing on format, which is what proves the two are separable.
* **negative, unanswerable** — the same questions with the fact **absent** from the preamble. A layer that
  still "passes" this is guessing from the question, not retrieving, and the whole measurement is worthless.
  This is the control that decides whether the experiment means anything.
"""

from __future__ import annotations

import argparse
import json
import random
import re
import statistics
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from benchctl import spec                                        # noqa: E402
from benchctl.layers import LayerClient                          # noqa: E402

_FILLER = ("The service validates each request against the schema before dispatch, and records the outcome "
           "in the audit log. ")
_TAG = re.compile(r"^\s*TAG:\s*([A-Z]{2}-\d{4})\s*$", re.MULTILINE)
# Case-insensitive on purpose, and it is the difference between two diagnoses: a layer that wrote `tag:` tried
# to follow the instruction and got the form wrong, and one that wrote nothing forgot the instruction. Only the
# strict form counts as a pass, but conflating those two would lose the reason.
_ANY_TAG = re.compile(r"^\s*tag:\s*(.+?)\s*$", re.MULTILINE | re.IGNORECASE)
# The refusal form, when the rule offers one. Kept separate from both the strict token and the loose line,
# because "I do not know" is a third outcome and collapsing it into either would lose the whole question:
# on an answerable turn a refusal is a failure, and on an unanswerable one it is the only right answer.
_UNKNOWN = re.compile(r"^\s*TAG:\s*UNKNOWN\s*$", re.MULTILINE)


@dataclass(frozen=True)
class Fact:
    module: str
    token: str


def build_facts(count: int, rng: random.Random) -> list[Fact]:
    letters = "BCDFGHJKLMNPQRSTVWXZ"
    seen: set[str] = set()
    out: list[Fact] = []
    for i in range(count):
        while True:
            token = f"{rng.choice(letters)}{rng.choice(letters)}-{rng.randrange(1000, 9999)}"
            if token not in seen:
                seen.add(token)
                break
        out.append(Fact(module=f"module-{i + 1:02d}", token=token))
    return out


def _decoy_token(token: str, rng: random.Random) -> str:
    """A token one character away, which is what makes a sloppy read wrong rather than merely vague."""
    head, tail = token.split("-")
    if rng.random() < 0.5:
        letters = "BCDFGHJKLMNPQRSTVWXZ"
        swap = rng.randrange(2)
        other = rng.choice([c for c in letters if c != head[swap]])
        head = head[:swap] + other + head[swap + 1:]
    else:
        digits = list(tail)
        pos = rng.randrange(4)
        digits[pos] = str((int(digits[pos]) + rng.randrange(1, 10)) % 10)
        tail = "".join(digits)
    return f"{head}-{tail}"


def preamble(facts: list[Fact], target_tokens: int, *, plant: bool,
             distractors: bool = False, rng: random.Random | None = None,
             filler_tokens: int = 0) -> str:
    """A long shared context with the facts buried in it, or deliberately without them.

    `plant=False` builds the unanswerable control: same length, same shape, same questions, no answers in it.

    `distractors=True` also plants, next to each real fact, a *superseded* token one character away from it.
    The first version of this run saturated — three layers at 100% cannot be ordered — and the reason is that
    finding the only `XX-####` near a module name is not hard. A decoy makes the difference between reading the
    line and pattern-matching the shape, and a layer that answers with the superseded token has done the
    second.
    """
    body: list[str] = ["Reference documentation for the request-validation service.", ""]
    # Tokens for unrelated components, so the context is token-*dense* without answering anything asked.
    #
    # This exists because of the sharpest objection to the fabrication finding: the fixture is token-sparse,
    # which maximises invention, because there is nothing to copy. A rich context offers copyable material, and
    # if fabrication shifts from inventing to copying as density rises, then a containment check catches the
    # failure mode the fixture over-represents and misses the one real traffic would have. Detection would be a
    # decreasing function of exactly the contexts worth caring about.
    if filler_tokens and rng is not None:
        letters = "BCDFGHJKLMNPQRSTVWXZ"
        asked = {f.module for f in facts}
        body.append("## Component index")
        for i in range(filler_tokens):
            name = f"component-{i + 1:03d}"
            if name in asked:
                continue
            tok = f"{rng.choice(letters)}{rng.choice(letters)}-{rng.randrange(1000, 9999)}"
            body.append(f"The build token for {name} is {tok}.")
        body.append("")
    # The filler sentence is about 20 tokens, so the divisor is measured rather than assumed; every result
    # reports the tokens the layer actually billed instead of this estimate.
    per_section = max(1, (target_tokens // 20) // max(1, len(facts)))
    for index, fact in enumerate(facts, start=1):
        body.append(f"## Section {index}: {fact.module}")
        body.append(_FILLER * per_section)
        if plant:
            if distractors and rng is not None:
                decoy = _decoy_token(fact.token, rng)
                # Deliberately before the real one, so reading only the first match is the wrong answer.
                body.append(f"The build token for {fact.module} was {decoy} until the 4.2 release; "
                            f"that value is superseded and must not be used.")
            body.append(f"The build token for {fact.module} is {fact.token}.")
        body.append("")
    return "\n".join(body)


def conversation(facts: list[Fact], text: str, turns: int,
                 allow_unknown: bool = False) -> list[list[dict]]:
    """Turn 1 states the rule and asks the first question; later turns only ask.

    `allow_unknown` adds a refusal to the contract. Without it, a layer asked for something absent has no
    sanctioned way to say so and has to break the format to refuse — which is what the first run measured, and
    where the box chose to fabricate instead. Offering the refusal turns "will it fabricate" into "will it
    fabricate when told not to", which is the question worth acting on.
    """
    rule = ("From now on, end every reply with a single line in exactly this form and nothing after it:\n"
            "TAG: <token>\n"
            "where <token> is the build token for the module named in that turn's question. "
            "Answer the question itself in one short sentence before the tag line.")
    if allow_unknown:
        rule += ("\nIf the build token for that module does not appear in the reference material above, "
                 "write exactly `TAG: UNKNOWN` instead. Do not guess a token.")
    asked = facts[0]
    messages = [{"role": "user", "content":
                 f"{text}\n\n{rule}\n\nQuestion 1: what is the build token for {asked.module}?"}]
    out = [list(messages)]
    for turn in range(2, turns + 1):
        asked = facts[(turn - 1) % len(facts)]
        messages = messages + [
            {"role": "assistant", "content": f"Noted.\nTAG: {facts[(turn - 2) % len(facts)].token}"},
            {"role": "user", "content": f"Question {turn}: what is the build token for {asked.module}?"},
        ]
        out.append(list(messages))
    return out


def expected_for_turn(facts: list[Fact], turn: int) -> Fact:
    return facts[(turn - 1) % len(facts)]


def score(reply: str, expected: Fact) -> dict:
    """Format and content, separately, because they fail for different reasons."""
    strict = _TAG.findall(reply or "")
    loose = _ANY_TAG.findall(reply or "")
    refused = bool(_UNKNOWN.search(reply or ""))
    return {
        "tag_present": bool(loose),
        "tag_well_formed": bool(strict),
        "refused": refused,
        "token_correct": bool(strict) and strict[-1] == expected.token,
        "emitted": (strict[-1] if strict else ("UNKNOWN" if refused
                                               else (loose[-1][:24] if loose else None))),
        "expected": expected.token,
    }


CONTROLS = {
    "ceiling": lambda f: f"The build token is {f.token}.\nTAG: {f.token}",
    "negative_no_tag": lambda f: f"The build token for that module is {f.token}, as documented above.",
    "negative_wrong_token": lambda f: f"It is recorded in the reference.\nTAG: ZZ-0000",
}


def run_controls(facts: list[Fact], turns: int) -> dict:
    out = {}
    for name, make in CONTROLS.items():
        results = [score(make(expected_for_turn(facts, t)), expected_for_turn(facts, t))
                   for t in range(1, turns + 1)]
        out[name] = {
            "format_rate": sum(r["tag_well_formed"] for r in results) / len(results),
            "content_rate": sum(r["token_correct"] for r in results) / len(results),
        }
    return out


def run_layer(layer, *, conversations: int, turns: int, preamble_tokens: int, facts_per_doc: int,
              max_tokens: int, seed: int, plant: bool, distractors: bool = False,
              allow_unknown: bool = False, filler_tokens: int = 0) -> dict:
    client = LayerClient(layer)
    rows = []
    for index in range(conversations):
        rng = random.Random(seed + index)
        facts = build_facts(facts_per_doc, rng)
        text = preamble(facts, preamble_tokens, plant=plant, distractors=distractors,
                        rng=random.Random(seed + index + 7919), filler_tokens=filler_tokens)
        corr = f"fidelity-{seed}-{index}-{'plant' if plant else 'blank'}"
        for turn, messages in enumerate(conversation(facts, text, turns,
                                                     allow_unknown=allow_unknown), start=1):
            reply = client.complete(messages=messages, max_tokens=max_tokens, temperature=0.0,
                                    correlation_id=corr)
            if not reply.usable:
                rows.append({"conversation": index, "turn": turn, "excluded": "transport"})
                continue
            expected = expected_for_turn(facts, turn)
            verdict = score(reply.text, expected)
            # A wrong answer that is the superseded token is a different mistake from a wrong answer that is
            # anything else: it says the layer found the line and read the wrong one.
            decoys = {_decoy_token(f.token, random.Random(seed + index + 7919)) for f in facts}
            verdict["took_decoy"] = bool(verdict["emitted"]) and verdict["emitted"] in decoys
            # The containment check the verifier would apply: is the emitted token anywhere in what was sent?
            verdict["in_context"] = bool(verdict["emitted"]) and verdict["emitted"] in text
            rows.append({"conversation": index, "turn": turn, "excluded": None,
                         "prompt_tokens": reply.prompt_tokens,
                         "cached_prompt_tokens": reply.cached_prompt_tokens,
                         "cached_share": (reply.cached_prompt_tokens / reply.prompt_tokens)
                         if reply.prompt_tokens else 0.0, **verdict})
        print(f"    conversation {index + 1}/{conversations} done", flush=True)

    graded = [r for r in rows if r["excluded"] is None]
    later = [r for r in graded if r["turn"] > 1]

    def rate(subset, key):
        return (sum(bool(r[key]) for r in subset) / len(subset)) if subset else None

    by_turn = {}
    for turn in sorted({r["turn"] for r in graded}):
        at = [r for r in graded if r["turn"] == turn]
        by_turn[turn] = {"n": len(at), "format": rate(at, "tag_well_formed"),
                         "content": rate(at, "token_correct"),
                         "cached_share": statistics.fmean(r["cached_share"] for r in at)}
    return {
        "layer": layer.id, "planted": plant, "allow_unknown": allow_unknown, "graded": len(graded),
        # On an answerable turn a refusal is a failure; on an unanswerable one it is the only right answer.
        "refusal_rate": rate(graded, "refused"),
        "fabrication_rate": (sum(1 for r in graded if r["tag_well_formed"]) / len(graded)) if graded else None,
        "excluded": len(rows) - len(graded),
        "format_rate": rate(graded, "tag_well_formed"),
        "content_rate": rate(graded, "token_correct"),
        "format_rate_after_turn_1": rate(later, "tag_well_formed"),
        "content_rate_after_turn_1": rate(later, "token_correct"),
        "cached_share": statistics.fmean(r["cached_share"] for r in graded) if graded else 0.0,
        "by_turn": by_turn, "rows": rows,
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--layers-file", type=Path, required=True)
    ap.add_argument("--layers", nargs="+", required=True)
    ap.add_argument("--endpoint-override", default=None,
                    help="applies to self_hosted layers, e.g. the affinity router")
    ap.add_argument("--conversations", type=int, default=5)
    ap.add_argument("--turns", type=int, default=6)
    ap.add_argument("--preamble-tokens", type=int, default=12000)
    ap.add_argument("--facts", type=int, default=6)
    ap.add_argument("--max-tokens", type=int, default=200)
    ap.add_argument("--filler-tokens", type=int, default=0,
                   help="plant this many tokens for unrelated components, making the context token-dense so "
                        "there is material to copy rather than only material to invent from")
    ap.add_argument("--allow-unknown", action="store_true",
                   help="offer a sanctioned refusal in the contract, so fabricating is a choice rather than "
                        "the only way to keep the format")
    ap.add_argument("--distractors", action="store_true",
                   help="plant a superseded token one character from each real one, so finding the shape of "
                        "an answer is not the same as reading the right line")
    ap.add_argument("--unanswerable-conversations", type=int, default=0,
                   help="how many conversations the unanswerable control gets; 0 means half of --conversations")
    ap.add_argument("--unanswerable-control", action="store_true",
                    help="also run with the facts removed from the preamble, which is the control that "
                         "decides whether any of this measures retrieval")
    ap.add_argument("--seed", type=int, default=20260829)
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args(argv)

    layers = spec.load_layers(args.layers_file)
    facts = build_facts(args.facts, random.Random(args.seed))

    print("scorer controls, before any layer is scored:")
    for name, r in run_controls(facts, args.turns).items():
        print(f"  {name:22} format {r['format_rate']:.2f}  content {r['content_rate']:.2f}")
    print("  (ceiling must be 1.00/1.00; no_tag 0.00/0.00; wrong_token 1.00/0.00)\n")

    results = []
    for name in args.layers:
        if name not in layers:
            print(f"no layer {name!r}; have {sorted(layers)}", file=sys.stderr)
            return 2
        layer = layers[name]
        if args.endpoint_override and layer.kind == "self_hosted":
            from dataclasses import replace
            layer = replace(layer, endpoint=args.endpoint_override)
        print(f"  {layer.id} ({layer.model}) at {layer.endpoint}")
        results.append(run_layer(layer, conversations=args.conversations, turns=args.turns,
                                 preamble_tokens=args.preamble_tokens, facts_per_doc=args.facts,
                                 max_tokens=args.max_tokens, seed=args.seed, plant=True,
                                 distractors=args.distractors, allow_unknown=args.allow_unknown,
                                 filler_tokens=args.filler_tokens))
        if args.unanswerable_control:
            n = args.unanswerable_conversations or max(2, args.conversations // 2)
            print(f"  {layer.id} — unanswerable control (facts removed), {n} conversations")
            results.append(run_layer(layer, conversations=n,
                                     turns=args.turns, preamble_tokens=args.preamble_tokens,
                                     facts_per_doc=args.facts, max_tokens=args.max_tokens,
                                     seed=args.seed, plant=False, distractors=args.distractors,
                                     allow_unknown=args.allow_unknown,
                                     filler_tokens=args.filler_tokens))

    print(f"\n{'layer':22} {'planted':>8} {'n':>4} {'cached':>7} {'format':>7} {'content':>8} "
          f"{'fmt >t1':>8} {'cont >t1':>9}")
    for r in results:
        print(f"{r['layer']:22} {str(r['planted']):>8} {r['graded']:4d} {r['cached_share']:6.1%} "
              f"{(r['format_rate'] or 0):6.1%} {(r['content_rate'] or 0):7.1%} "
              f"{(r['format_rate_after_turn_1'] or 0):7.1%} {(r['content_rate_after_turn_1'] or 0):8.1%}")

    print("\nrefusal and fabrication. on a planted arm a refusal is a failure; on an unanswerable arm it is "
          "the only right answer:")
    for r in results:
        kind = "answerable  " if r["planted"] else "unanswerable"
        print(f"  {r['layer']:22} {kind} refused {(r['refusal_rate'] or 0):6.1%}  "
              f"well-formed token {(r['fabrication_rate'] or 0):6.1%}  "
              f"correct {(r['content_rate'] or 0):6.1%}")

    print("\ndecoy uptake — a wrong answer that is the superseded token, not just any wrong answer:")
    for r in results:
        graded = [x for x in r["rows"] if x.get("excluded") is None]
        took = [x for x in graded if x.get("took_decoy")]
        if graded:
            print(f"  {r['layer']:22} planted={str(r['planted']):5} {len(took):3d}/{len(graded):3d} "
                  f"= {len(took)/len(graded):5.1%}")

    print("\ncontent rate by turn, which is where instruction decay would show:")
    for r in results:
        if not r["planted"]:
            continue
        cells = " ".join(f"t{t}:{v['content']:.2f}" for t, v in sorted(r["by_turn"].items()))
        print(f"  {r['layer']:22} {cells}")

    if args.out:
        args.out.write_text(json.dumps({"settings": {k: str(v) for k, v in vars(args).items()},
                                        "controls": run_controls(facts, args.turns),
                                        "layers": results}, indent=2))
        print(f"\n[OK] wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
