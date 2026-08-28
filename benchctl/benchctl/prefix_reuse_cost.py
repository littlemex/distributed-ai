"""What agentic-shaped traffic costs on each layer, with both sides measured instead of one.

The agentic family is the one this project was built to serve and the only one whose headline number was never
measured on both sides. `results-agentx.md` measures the box against a *computed* API arm: AgentX's token counts
priced at `claude-haiku-4-5`'s list rate with an assumed 94% cache hit rate. Two things later turned out to be
wrong with that arm, in opposite directions, and neither could have been seen without sending a request:

* `claude-haiku-4-5` returns **zero** cached tokens on this gateway, in every request shape probed. Its 94% row
  is unreachable, which is why the family's sign flips to the box being cheaper.
* The premium layers reach **99.8%** on the shape this traffic actually sends, so the discount does exist here
  — it just does not come with a low price.

And a third question arrived from the pricing correction and is now the live one. `gemma-4` is the cheapest
layer measured in both other families, at AWS's published $0.14 / $0.40. But it does not cache, in any shape,
at any length. So on traffic that reuses a long prefix its flat rate competes against the box's *cached* rate
of $0.0188 per Mtok — 8.2% of the box's fresh rate, measured in `cached_prefill_rate.py`. The prediction is
that prefix reuse is exactly where the box beats the cheap tier, and it is the only claim that would make
"route this to the box" the right answer rather than "route it to gemma-4".

## The shape, and why it is synthetic on purpose

Cost is a function of the shape of the traffic, not of what it says. What decides it here is how many prompt
tokens each turn carries, how much of that is a prefix an earlier turn already established, and how many
tokens come back. So the conversations are built to AgentX's *measured* shape — a long shared preamble
standing in for a system prompt and tool definitions, a per-conversation history that grows by a turn each
time, and a bounded reply — rather than replaying its corpus, which cannot be pointed at this gateway without
a tokenizer for models that do not publish one.

That makes every quality claim out of scope, and the family already has quality measured elsewhere. What this
produces is a bill, per layer, on identical traffic, from the provider's own usage numbers and a rate with a
source.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from benchctl import spec                                        # noqa: E402
from benchctl.layers import LayerClient                          # noqa: E402

# Filler for the shared preamble and the per-turn history. Neutral text: the measurement is of token counts.
_CLAUSE = "The repository contains a module that handles request validation. "


# How much the model is asked to write. This is not a detail: the box's output rate is $4.12 per Mtok against
# gemma-4's $0.40, so the output share decides who wins as much as the cache does. AgentX's corpus is
# 6,891,228,864 input tokens against 58,728,807 output — 117:1 — and a run that caps output at 96 tokens is
# eleven times more prefill-dominated than the traffic it claims to model, which flatters whichever layer is
# cheapest on input. The first version of this instrument did exactly that.
_ANSWER_SHORT = "Answer in one sentence."
_ANSWER_REALISTIC = ("Answer in about {words} words, describing what you would inspect and why, as an "
                     "engineer writing a note to themselves.")


def answer_instruction(output_words: int) -> str:
    return _ANSWER_SHORT if output_words <= 0 else _ANSWER_REALISTIC.format(words=output_words)


def conversation_turns(*, preamble_tokens: int, turn_tokens: int, turns: int,
                       conversation: int, output_words: int = 0) -> list[list[dict]]:
    """One conversation, as the message array it would be sent as at each turn.

    Turn N carries every earlier turn verbatim, which is what makes the prefix reusable and is the whole point:
    a harness that re-asked a single question would measure a different regime.
    """
    # The clause is about 12 tokens, so the divisor is not a guess: it is what makes the requested
    # size the size that arrives. Every result reports the tokens the layer billed, not this estimate.
    shared = _CLAUSE * max(1, preamble_tokens // 12)             # identical across conversations
    ask = answer_instruction(output_words)
    opening = (f"System context (identical for every conversation):\n{shared}\n\n"
               f"Task {conversation}: describe the first step you would take. {ask}")
    messages: list[dict] = [{"role": "user", "content": opening}]
    out = [list(messages)]
    for turn in range(2, turns + 1):
        # A reply of the size the agent's own tool output would be, then the next instruction. Both go into
        # the prefix that the following turn reuses.
        history = _CLAUSE * max(1, turn_tokens // 12)
        messages = messages + [
            {"role": "assistant", "content": f"Step {turn - 1} noted."},
            {"role": "user", "content": f"Tool output for step {turn - 1}:\n{history}\n\n"
                                        f"Task {conversation}, turn {turn}: what next? {ask}"},
        ]
        out.append(list(messages))
    return out


def run_layer(layer, *, conversations: int, turns: int, preamble_tokens: int, turn_tokens: int,
              max_tokens: int, output_words: int = 0) -> dict:
    client = LayerClient(layer)
    rows, api_usd, box_usd, box_seconds, failures = [], 0.0, 0.0, 0.0, 0
    started = time.perf_counter()
    for conversation in range(conversations):
        for turn_index, messages in enumerate(
                conversation_turns(preamble_tokens=preamble_tokens, turn_tokens=turn_tokens,
                                   turns=turns, conversation=conversation,
                                   output_words=output_words), start=1):
            reply = client.complete(messages=messages, max_tokens=max_tokens, temperature=0.0)
            if not reply.usable:
                failures += 1
                continue
            cost = client.cost(reply)
            api_usd += cost.api_usd
            box_usd += cost.box_usd_at_full_utilisation
            box_seconds += cost.box_seconds
            rows.append({"conversation": conversation, "turn": turn_index,
                         "prompt_tokens": reply.prompt_tokens,
                         "cached_prompt_tokens": reply.cached_prompt_tokens,
                         "completion_tokens": reply.completion_tokens,
                         "latency_s": round(reply.latency_s, 4),
                         "usd": cost.api_usd or cost.box_usd_at_full_utilisation})
        print(f"    conversation {conversation + 1}/{conversations} done", flush=True)
    prompt = sum(r["prompt_tokens"] for r in rows)
    cached = sum(r["cached_prompt_tokens"] for r in rows)
    usd = api_usd or box_usd
    # Turn 1 cannot hit, so the reuse a layer achieves is best read over the turns that could.
    later = [r for r in rows if r["turn"] > 1]
    later_prompt = sum(r["prompt_tokens"] for r in later)
    later_cached = sum(r["cached_prompt_tokens"] for r in later)
    return {
        "layer": layer.id, "model": layer.model, "kind": layer.kind,
        "pricing_status": layer.pricing_status, "pricing_key": layer.pricing_key,
        "requests": len(rows), "failures": failures,
        "prompt_tokens": prompt, "cached_prompt_tokens": cached,
        "cached_share": (cached / prompt) if prompt else 0.0,
        "cached_share_after_first_turn": (later_cached / later_prompt) if later_prompt else 0.0,
        "completion_tokens": sum(r["completion_tokens"] for r in rows),
        "input_to_output_ratio": (prompt / sum(r["completion_tokens"] for r in rows)
                                  if sum(r["completion_tokens"] for r in rows) else None),
        "usd_total": usd,
        "usd_per_request": (usd / len(rows)) if rows else None,
        "latency_p50_s": statistics.median(r["latency_s"] for r in rows) if rows else None,
        "wall_s": time.perf_counter() - started,
        "rows": rows,
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--run", type=Path, required=True, help="a run spec, read only for its layers and rates")
    ap.add_argument("--layers", nargs="*", default=None)
    ap.add_argument("--conversations", type=int, default=6)
    ap.add_argument("--turns", type=int, default=6)
    ap.add_argument("--preamble-tokens", type=int, default=12000)
    ap.add_argument("--turn-tokens", type=int, default=1500)
    ap.add_argument("--max-tokens", type=int, default=96)
    ap.add_argument("--output-words", type=int, default=0,
                   help="ask for roughly this many words back; 0 asks for one sentence, which makes output "
                        "negligible and flatters whichever layer is cheapest on input")
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args(argv)

    layers = spec.load_layers(args.run)
    chosen = [layers[i] for i in (args.layers or sorted(layers)) if i in layers]
    print(f"{args.conversations} conversations x {args.turns} turns, {args.preamble_tokens}-token shared "
          f"preamble, {args.turn_tokens} tokens added per turn\n")

    results = []
    for layer in chosen:
        print(f"  {layer.id} ({layer.model})")
        results.append(run_layer(layer, conversations=args.conversations, turns=args.turns,
                                 preamble_tokens=args.preamble_tokens, turn_tokens=args.turn_tokens,
                                 max_tokens=args.max_tokens, output_words=args.output_words))

    print(f"\n{'layer':22} {'reqs':>5} {'prompt tok':>11} {'cached':>7} {'after t1':>9} {'in:out':>8} "
          f"{'$/1k reqs':>10} {'p50':>7}  pricing")
    for r in sorted(results, key=lambda r: (r["usd_per_request"] is None, r["usd_per_request"] or 0)):
        per_1k = f"{r['usd_per_request'] * 1000:10.3f}" if r["usd_per_request"] else "  unpriced"
        ratio = f"{r['input_to_output_ratio']:7.0f}:1" if r.get("input_to_output_ratio") else "      -"
        print(f"{r['layer']:22} {r['requests']:5d} {r['prompt_tokens']:11,d} "
              f"{r['cached_share']:6.1%} {r['cached_share_after_first_turn']:8.1%} {ratio} {per_1k} "
              f"{r['latency_p50_s'] or 0:6.2f}s  {r['pricing_status']}")
    if args.out:
        args.out.write_text(json.dumps({"settings": vars(args) | {"run": str(args.run)},
                                        "layers": results}, indent=2, default=str))
        print(f"\n[OK] wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
