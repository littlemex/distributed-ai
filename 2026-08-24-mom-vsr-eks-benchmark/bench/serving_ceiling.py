#!/usr/bin/env python3
"""What the self-hosted server can actually take, and what that makes a token cost.

    VLLM_URL=http://127.0.0.1:18000 ./serving_ceiling.py --hourly 15.2174

A rented GPU costs its hourly rate whether or not a request arrives, so the price of a
token on it is the hourly rate divided by what it actually served. That makes utilisation
the price — and it makes the capacity ceiling the number a routing policy has to know
before it can fill the machine without queueing behind itself.

Three things are measured, in this order, because each is cheap and the later ones only
matter if the earlier ones came out as expected:

* **the realised price today**, from the server's own lifetime counters. No load added.
* **the ceiling**, by raising concurrency until throughput stops rising and latency starts.
  The knee is where a policy should stop sending, minus a safety factor.
* **whether a repeated prefix is free**, which decides whether multi-turn work on this
  server is as cheap as it looks.

Every request asks for the same number of tokens with `ignore_eos`, so a throughput figure
is not partly a measurement of how talkative the model felt.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import statistics
import sys
import time
from pathlib import Path

import aiohttp

PROMPT_UNIT = (
    "The greenhouse roof was replaced in spring, and the gardener keeps the seed trays on "
    "the north bench where the light is even. Beans go in along the south fence. "
)


def prompt_of(words: int, salt: str = "") -> str:
    unit = PROMPT_UNIT.split()
    out = [salt] if salt else []
    while len(out) < words:
        out.extend(unit)
    return " ".join(out[:words])


async def counters(session: aiohttp.ClientSession, base: str) -> dict[str, float]:
    """The server's own lifetime totals, which need no load to read."""
    async with session.get(f"{base}/metrics") as response:
        text = await response.text()
    wanted = {
        "vllm:prompt_tokens_total": "prompt_tokens",
        "vllm:generation_tokens_total": "generation_tokens",
        "vllm:num_requests_running": "running",
        "vllm:num_requests_waiting": "waiting",
    }
    out: dict[str, float] = {}
    for line in text.splitlines():
        for metric, name in wanted.items():
            if line.startswith(metric + "{"):
                out[name] = float(line.rsplit(" ", 1)[1])
    return out


async def one(
    session: aiohttp.ClientSession,
    base: str,
    model: str,
    prompt: str,
    tokens: int,
) -> dict[str, float]:
    started = time.perf_counter()
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": tokens,
        # Fixes the output length so throughput is not partly a measure of verbosity.
        "ignore_eos": True,
        "temperature": 0,
    }
    async with session.post(f"{base}/v1/chat/completions", json=body) as response:
        payload = await response.json()
    elapsed = time.perf_counter() - started
    usage = payload.get("usage") or {}
    return {
        "seconds": elapsed,
        "completion_tokens": float(usage.get("completion_tokens") or 0),
        "prompt_tokens": float(usage.get("prompt_tokens") or 0),
        "status": float(response.status),
    }


async def at_concurrency(
    session: aiohttp.ClientSession,
    base: str,
    model: str,
    *,
    concurrency: int,
    requests: int,
    prompt_words: int,
    tokens: int,
) -> dict[str, float]:
    """Send `requests` calls with at most `concurrency` in flight, and time the batch."""
    gate = asyncio.Semaphore(concurrency)
    prompts = [prompt_of(prompt_words, f"run-{concurrency}-{i}") for i in range(requests)]

    async def guarded(prompt: str):
        async with gate:
            return await one(session, base, model, prompt, tokens)

    started = time.perf_counter()
    results = await asyncio.gather(*(guarded(p) for p in prompts))
    wall = time.perf_counter() - started
    latencies = sorted(r["seconds"] for r in results)
    generated = sum(r["completion_tokens"] for r in results)
    return {
        "concurrency": concurrency,
        "requests": len(results),
        "wall_s": wall,
        "output_tokens_per_s": generated / wall if wall else 0.0,
        "requests_per_s": len(results) / wall if wall else 0.0,
        "p50_s": statistics.median(latencies),
        "p95_s": latencies[min(len(latencies) - 1, int(0.95 * len(latencies)))],
        "generated": generated,
    }


def price_per_mtok(hourly: float, tokens_per_s: float) -> float:
    """What an output token costs at this throughput, from the hourly rate alone."""
    if tokens_per_s <= 0:
        return float("inf")
    return hourly / (tokens_per_s * 3600) * 1e6


async def main_async(args) -> int:
    base = (os.environ.get("VLLM_URL") or args.url).rstrip("/")
    print(f"[INFO] {base}, model {args.model}, hourly rate ${args.hourly}")

    async with aiohttp.ClientSession(
        timeout=aiohttp.ClientTimeout(total=args.timeout)
    ) as session:
        before = await counters(session, base)
        if before.get("running", 0) or before.get("waiting", 0):
            print(
                f"[WARNING] the server is busy (running={before.get('running')}, "
                f"waiting={before.get('waiting')}); the numbers below will include "
                "someone else's traffic and the queue it is in"
            )
        print(
            f"[INFO] lifetime so far: {before.get('generation_tokens', 0):,.0f} output "
            f"tokens, {before.get('prompt_tokens', 0):,.0f} prompt tokens"
        )
        if args.uptime_hours:
            spent = args.uptime_hours * args.hourly
            realised = price_per_mtok(
                args.hourly, before.get("generation_tokens", 0) / (args.uptime_hours * 3600)
            )
            print(
                f"[INFO] {args.uptime_hours:.0f} h at this rate is ${spent:,.0f} spent, so "
                f"the realised price is ${realised:,.0f}/Mtok of output — a number about "
                "idleness, not about the model"
            )

        rows = []
        print(
            f"\n    {'conc':>5}{'req/s':>8}{'out tok/s':>11}{'p50 s':>8}{'p95 s':>8}"
            f"{'$/Mtok out':>12}"
        )
        for concurrency in args.concurrency:
            row = await at_concurrency(
                session,
                base,
                args.model,
                concurrency=concurrency,
                requests=max(concurrency * args.requests_per_slot, 4),
                prompt_words=args.prompt_words,
                tokens=args.tokens,
            )
            row["usd_per_mtok_out"] = price_per_mtok(args.hourly, row["output_tokens_per_s"])
            rows.append(row)
            print(
                f"    {row['concurrency']:>5}{row['requests_per_s']:>8.2f}"
                f"{row['output_tokens_per_s']:>11.1f}{row['p50_s']:>8.1f}"
                f"{row['p95_s']:>8.1f}{row['usd_per_mtok_out']:>12,.2f}"
            )

        best = max(rows, key=lambda r: r["output_tokens_per_s"])
        print(
            f"\n    throughput peaks at concurrency {best['concurrency']:.0f} with "
            f"{best['output_tokens_per_s']:.0f} output tokens/s, which prices a token at "
            f"${best['usd_per_mtok_out']:,.2f}/Mtok"
        )
        print(
            f"    a policy should stop at about {best['concurrency'] * args.safety:.0f} in "
            f"flight ({args.safety:.0%} of the peak) and spill the rest"
        )

        # Written before the last probe: the sweep is the expensive part and a dropped
        # connection during a cheap follow-up must not take it with it.
        Path(args.out).write_text(
            json.dumps({"before": before, "sweep": rows}, ensure_ascii=False, indent=2)
        )
        print(f"\n[OK] sweep -> {args.out}")

        # Does a repeated prefix cost anything? With prefix caching off it does.
        try:
            repeated = prompt_of(args.prompt_words, "repeat-probe")
            first = await one(session, base, args.model, repeated, args.tokens)
            second = await one(session, base, args.model, repeated, args.tokens)
            print(
                f"\n    the same prompt twice: {first['seconds']:.2f}s then "
                f"{second['seconds']:.2f}s "
                f"({(1 - second['seconds'] / first['seconds']):+.0%} on the second)"
            )
            print(
                "    a server with prefix caching on answers the second much faster; one "
                "with it off pays for the prompt again every turn, which is what a "
                "multi-turn agent session is made of"
            )
        except aiohttp.ClientError as exc:
            print(f"\n[WARNING] the repeat probe did not complete: {exc}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--url", default="http://127.0.0.1:18000")
    parser.add_argument("--model", default="Qwen/Qwen3.8-27B")
    parser.add_argument("--concurrency", nargs="+", type=int, default=[1, 2, 4, 8])
    parser.add_argument("--requests-per-slot", type=int, default=3)
    parser.add_argument("--prompt-words", type=int, default=400)
    parser.add_argument("--tokens", type=int, default=128)
    parser.add_argument("--hourly", type=float, default=15.2174)
    parser.add_argument("--uptime-hours", type=float, default=None)
    parser.add_argument("--safety", type=float, default=0.7)
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument("--out", default="results/serving-ceiling.json")
    return asyncio.run(main_async(parser.parse_args(argv)))


if __name__ == "__main__":
    sys.exit(main())
