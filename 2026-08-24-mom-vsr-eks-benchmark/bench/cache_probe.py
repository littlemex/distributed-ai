#!/usr/bin/env python3
"""Does the prompt cache exist on this path, and what does a model switch cost?

    VSR_URL=http://127.0.0.1:18801/v1/chat/completions ./cache_probe.py \
        --models sclv/claude-fable-5 sclv/gpt-5.6-terra sclv/grok-4.6

The first thing v3 has to establish, because everything downstream is priced on it. In a
long agentic session almost every input token should be a prefix-cache hit, and a hit
costs about a tenth of a fresh token. If that is true, the premium baseline is far cheaper
than its list price and switching models mid-session pays a tax on the whole accumulated
context. If it is false, the baseline is expensive and the tax does not exist — which
inverts the design conclusion, so it is worth ten minutes before it is worth a sandbox.

The probe grows one conversation turn by turn against a stable prefix, which is the shape
an agent session has, and reads back what the provider says it charged for. Then it sends
the same conversation to a different model, which is the switch: a cache built by one
model is worth nothing to another.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path

import aiohttp

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from harness import client  # noqa: E402

# Long enough to clear every provider's minimum cacheable prefix (commonly 1,024 or 2,048
# tokens) with room to spare. The subject matter is deliberately dull: a first attempt used
# prose about the harness itself and one model answered with a content-filter refusal and
# zero tokens, which looks exactly like a usage-reporting bug and is not one.
PREFIX_PARAGRAPH = (
    "The garden path runs from the east gate to the old greenhouse. Rain collects in the "
    "stone trough beside it, and the gardener empties it each morning before the rows are "
    "watered. Beans are planted along the south fence where the soil drains well. "
)


def stable_prefix(words: int, salt: str = "") -> str:
    """A block of text of a given length, the stand-in for accumulated context.

    `salt` makes the prefix unique. Without it the probe deceives itself: the same
    deterministic text sent to a second model may already be in *that* model's cache from
    an earlier part of the same run, so a switch would look free when it is not.
    """
    unit = PREFIX_PARAGRAPH.split()
    out = [salt] if salt else []
    while len(out) < words:
        out.extend(unit)
    return " ".join(out[:words])


async def one_turn(
    session: aiohttp.ClientSession,
    url: str,
    model: str,
    messages: list[dict],
    api_key: str | None,
    max_tokens: int = 256,
) -> client.Call:
    return await client.call_once(
        session,
        url,
        stream=True,
        arm=f"probe:{model}",
        model=model,
        prompt="",  # the conversation is passed whole, below
        item_id="probe",
        dataset="cache-probe",
        category="probe",
        fold="probe",
        max_tokens=max_tokens,
        temperature=None,
        extra_headers={"authorization": f"Bearer {api_key}"} if api_key else {},
        messages=messages,
    )


async def probe_model(
    session: aiohttp.ClientSession,
    url: str,
    model: str,
    *,
    turns: int,
    prefix_words: int,
    api_key: str | None,
    max_tokens: int,
    salt: str,
) -> list[client.Call]:
    """Grow one conversation and watch the cache fill, turn by turn."""
    messages = [
        {
            "role": "user",
            "content": stable_prefix(prefix_words, salt)
            + "\n\nIn one short sentence: where are the beans planted?",
        }
    ]
    calls = []
    for turn in range(1, turns + 1):
        record = await one_turn(session, url, model, messages, api_key, max_tokens)
        calls.append(record)
        if record.error:
            break
        messages.append({"role": "assistant", "content": record.text or "(empty)"})
        messages.append(
            {"role": "user", "content": f"Now restate that in {turn + 1} words exactly."}
        )
    return calls


def report(model: str, calls: list[client.Call]) -> None:
    print(f"\n== {model} ==")
    print(f"    {'turn':>4}{'prompt':>9}{'cached':>9}{'written':>9}{'hit':>7}  note")
    for i, c in enumerate(calls, 1):
        if c.error:
            print(f"    {i:>4}  failed: {str(c.error)[:70]}")
            continue
        prompt = c.prompt_tokens or 0
        cached = c.cached_prompt_tokens
        written = c.cache_write_tokens
        hit = f"{cached / prompt:.0%}" if cached is not None and prompt else "-"
        note = "not reported" if cached is None else ""
        print(
            f"    {i:>4}{prompt:>9}"
            f"{'-' if cached is None else cached:>9}"
            f"{'-' if written is None else written:>9}{hit:>7}  {note}"
        )


async def main_async(args) -> int:
    url = os.environ.get("VSR_URL") or args.url
    if not url:
        raise SystemExit("[FAIL] set VSR_URL or pass --url")
    api_key = os.environ.get("STRATOCLAVE_API_KEY")
    print(f"[INFO] {url}, prefix ~{args.prefix_words} words, {args.turns} turns per model")

    connector = aiohttp.TCPConnector(limit=4)
    async with aiohttp.ClientSession(connector=connector) as session:
        collected = {}
        for model in args.models:
            collected[model] = await probe_model(
                session,
                url,
                model,
                turns=args.turns,
                prefix_words=args.prefix_words,
                api_key=api_key,
                max_tokens=args.max_tokens,
                salt=f"note-{model.replace('/', '-')}",
            )
            report(model, collected[model])

        if len(args.models) >= 2:
            # The switch: the same conversation, handed to a model that has never seen it.
            first, second = args.models[0], args.models[1]
            fresh = [
                {
                    "role": "user",
                    "content": stable_prefix(args.prefix_words, "switch-test-unseen")
                    + "\n\nIn one short sentence: where are the beans planted?",
                }
            ]
            warm = await one_turn(session, url, first, fresh, api_key, args.max_tokens)
            warm_again = await one_turn(
                session, url, first, fresh, api_key, args.max_tokens
            )
            switched = await one_turn(
                session, url, second, fresh, api_key, args.max_tokens
            )
            print("\n== the switch ==")
            for label, call in (
                (f"{first} (first sight)", warm),
                (f"{first} (same prompt again)", warm_again),
                (f"{second} (same prompt, new model)", switched),
            ):
                cached = call.cached_prompt_tokens
                print(
                    f"    {label:<44}prompt={call.prompt_tokens} "
                    f"cached={'not reported' if cached is None else cached}"
                )
            print(
                "    a second identical call should hit the cache; the new model should "
                "not. If neither reports it, this path has no prompt cache and the switch "
                "tax in SWITCH-ECONOMICS.md does not exist."
            )

    Path(args.out).write_text(
        json.dumps(
            {m: [c.to_json() for c in calls] for m, calls in collected.items()},
            ensure_ascii=False,
            indent=2,
        )
    )
    print(f"\n[OK] raw rows -> {args.out}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--url", default=None)
    parser.add_argument(
        "--models",
        nargs="+",
        default=["sclv/claude-fable-5", "sclv/gpt-5.6-terra", "sclv/grok-4.6"],
    )
    parser.add_argument("--turns", type=int, default=4)
    parser.add_argument("--prefix-words", type=int, default=6000)
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=256,
        help="a reasoning model can spend a small budget entirely on thinking and emit "
        "nothing, which is not a cache result",
    )
    parser.add_argument("--out", default="results/cache-probe.json")
    return asyncio.run(main_async(parser.parse_args(argv)))


if __name__ == "__main__":
    sys.exit(main())
