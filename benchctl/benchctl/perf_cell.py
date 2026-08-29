"""The perf cell: how many requests of this shape the box finishes in an hour, at the operating point.

This is the objective's denominator. `S_box` is the box time a family's requests consume, and it is a
property of the batch rather than of one call — at one request in flight the machine is idle between
tokens, and at the operating concurrency it is not. Measuring it at c=1 and multiplying is the mistake
this cell exists to prevent.

Deliberately not `sglang.benchmark.serving`, which is the better instrument and the intended
replacement: it ships the datasets this would otherwise invent and reports proper percentiles. Its image
filled a CPU node's disk and got the Job evicted, so until there is a node pool with disk requested for
it, this dependency-free stand-in runs instead. What it must not do is pretend to be that tool: it
reports what it measures and nothing more.
"""

from __future__ import annotations

import itertools
import json
import multiprocessing
import os
import random
import statistics
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


_SALT = itertools.count()


def salted(prompt: str) -> str:
    """A unique prefix per request, at the FRONT.

    Prefix caching is enabled now, and every synthetic shape in this file is identical padding. Without a
    salt these cells would measure the cache rather than the box — the hazard both advisors flagged back
    when it could not yet happen. It has to go at the front: a unique tail leaves everything before it
    cacheable, which is the same bug wearing a disguise.
    """
    return f"[run {os.getpid()}-{next(_SALT)}] {prompt}"


def _one(url: str, model: str, prompt: str, max_tokens: int, priority: int | None = None) -> dict:
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    # Sent only when asked. vLLM rejects a non-zero priority on an fcfs engine rather than ignoring
    # it, so an unconditional field would make the priority arm fail against the control's engine and
    # look like a latency result.
    if priority is not None:
        payload["priority"] = priority
    body = json.dumps(payload).encode()
    request = urllib.request.Request(url, data=body, headers={"content-type": "application/json"})
    started = time.perf_counter()
    ttft = None
    prompt_tokens = completion_tokens = 0
    with urllib.request.urlopen(request, timeout=1200) as response:
        for raw in response:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                continue
            event = json.loads(payload)
            if ttft is None and any((c.get("delta") or {}).get("content")
                                    for c in event.get("choices") or []):
                ttft = time.perf_counter() - started
            if event.get("usage"):
                prompt_tokens = event["usage"].get("prompt_tokens") or prompt_tokens
                completion_tokens = event["usage"].get("completion_tokens") or completion_tokens
    total = time.perf_counter() - started
    return {"ttft_s": ttft or total, "e2e_s": total,
            "prompt_tokens": prompt_tokens, "completion_tokens": completion_tokens}


_JOB: dict = {}


def _worker(share: tuple[int, int]) -> list[dict]:
    """One process's share of the offered load: `threads` in flight, `count` requests total.

    Processes rather than threads, because the generator was the bottleneck before it was: at the shortest
    shape two client pods together produced 1.37x what one produced, so a single Python process's GIL and
    SSE parsing were capping the number being reported as the box's ceiling. A load generator that cannot
    outrun the thing it measures does not measure it.
    """
    threads, count = share
    with ThreadPoolExecutor(max_workers=threads) as pool:
        return list(pool.map(lambda _: _one(_JOB["url"], _JOB["model"], salted(_JOB["prompt"]),
                                            _JOB["out_tokens"], _JOB.get("priority")),
                             range(count)))


def _init(job: dict) -> None:
    _JOB.update(job)


def offer(url: str, model: str, prompt: str, out_tokens: int, *, concurrency: int, count: int,
          workers: int, priority: int | None = None) -> tuple[list[dict], float]:
    """Offer `count` requests with `concurrency` in flight, spread over `workers` processes."""
    workers = max(1, min(workers, concurrency))
    per = [(concurrency // workers + (1 if i < concurrency % workers else 0)) for i in range(workers)]
    shares = [(threads, count * threads // concurrency) for threads in per]
    job = {"url": url, "model": model, "prompt": prompt, "out_tokens": out_tokens,
           "priority": priority}
    started = time.perf_counter()
    if workers == 1:
        _init(job)
        rows = _worker(shares[0])
    else:
        ctx = multiprocessing.get_context("fork")
        with ctx.Pool(workers, initializer=_init, initargs=(job,)) as pool:
            rows = [r for part in pool.map(_worker, shares) for r in part]
    return rows, time.perf_counter() - started


def sustainable_knee(url: str, model: str, prompt: str, out_tokens: int, hourly: float, *,
                     rounds: int, ttft_p95_slo: float, gain_floor: float = 0.10,
                     ladder=(1, 2, 4, 8, 16, 32, 64, 128), patience: int = 1) -> list[dict]:
    """Climb the concurrency ladder until throughput stops paying for the latency it costs.

    Two stopping rules, and both matter. Throughput that gains less than `gain_floor` is queueing rather
    than work, and a p95 time to first token past the SLO is a machine nobody would run at that point.
    Maximum throughput without an SLO overstates what a family can actually be served at.
    """
    points, best, stale = [], 0.0, 0
    workers = int(os.environ.get("LOAD_WORKERS", "1"))
    for c in ladder:
        rows, wall = offer(url, model, prompt, out_tokens,
                           concurrency=c, count=c * rounds, workers=workers)
        rph = len(rows) / wall * 3600
        ttfts = sorted(r["ttft_s"] for r in rows)
        p95 = ttfts[min(len(ttfts) - 1, int(0.95 * (len(ttfts) - 1)))]
        point = {
            "concurrency": c, "requests": len(rows), "wall_s": wall, "requests_per_hour": rph,
            "box_seconds_per_request": 3600 / rph if rph else None,
            "usd_per_request": hourly / rph if rph else None,
            "prompt_tokens_per_s": sum(r["prompt_tokens"] for r in rows) / wall,
            "completion_tokens_per_s": sum(r["completion_tokens"] for r in rows) / wall,
            "ttft_p50": statistics.median(r["ttft_s"] for r in rows), "ttft_p95": p95,
            "e2e_p50": statistics.median(r["e2e_s"] for r in rows),
            "within_slo": p95 <= ttft_p95_slo,
        }
        points.append(point)
        gain = (rph - best) / best if best else 1.0
        print(f"    c={c:>3}: {rph:9.0f} req/h (+{gain*100:5.1f}%) ttft p95 {p95:6.2f}s "
              f"{'' if point['within_slo'] else '[over SLO]'}", flush=True)
        best = max(best, rph)
        if p95 > ttft_p95_slo:
            break
        # One flat rung can be sampling noise; `patience` rungs of it is a ceiling. The first version
        # stopped on the first one and reported a knee that later runs walked straight past.
        stale = stale + 1 if (c > 1 and gain < gain_floor) else 0
        if stale >= patience:
            break
    return points


def run_perf_cell(out_dir: Path) -> dict:
    """Closed-loop load of one request shape, at one or more concurrencies."""
    url = os.environ["PERF_URL"]
    model = os.environ["PERF_MODEL"]
    hourly = float(os.environ.get("HOURLY_USD", "15.2174"))
    in_tokens = int(os.environ.get("INPUT_TOKENS", "2000"))
    out_tokens = int(os.environ.get("OUTPUT_TOKENS", "16"))
    rounds = int(os.environ.get("ROUNDS", "4"))
    levels = [int(x) for x in os.environ.get("CONCURRENCIES", "1,8,16,32").split(",")]
    out_dir.mkdir(parents=True, exist_ok=True)

    # Filler that tokenises like prose rather than like one repeated token, sized to the family's shape.
    words = [f"item{i}" for i in range(4096)]
    prompt = ("次の文章を読み、最後の一語だけで答えてください。\n\n"
              + " ".join(words[i % len(words)] for i in range(in_tokens // 4))
              + "\n\nこの文章の分類は ポジティブ / ネガティブ のどちらですか。")

    trace, points = [], []
    for c in levels:
        started = time.perf_counter()
        with ThreadPoolExecutor(max_workers=c) as pool:
            rows = list(pool.map(lambda _: _one(url, model, salted(prompt), out_tokens),
                                 range(c * rounds)))
        wall = time.perf_counter() - started
        for row in rows:
            trace.append({**row, "concurrency_at_send": c, "source": "benchctl.perf_cell"})
        prompt_total = sum(r["prompt_tokens"] for r in rows)
        completion_total = sum(r["completion_tokens"] for r in rows)
        requests_per_hour = len(rows) / wall * 3600
        point = {
            "concurrency": c,
            "requests": len(rows),
            "wall_s": wall,
            "requests_per_hour": requests_per_hour,
            # The objective's denominator: box seconds one request of this shape consumes at this point.
            "box_seconds_per_request": 3600 / requests_per_hour if requests_per_hour else None,
            "usd_per_request": hourly / requests_per_hour if requests_per_hour else None,
            "usd_per_1k_requests": hourly / requests_per_hour * 1000 if requests_per_hour else None,
            "prompt_tokens_per_s": prompt_total / wall,
            "completion_tokens_per_s": completion_total / wall,
            "ttft_p50": statistics.median(r["ttft_s"] for r in rows),
            "ttft_p90": sorted(r["ttft_s"] for r in rows)[int(0.9 * (len(rows) - 1))],
            "e2e_p50": statistics.median(r["e2e_s"] for r in rows),
            "e2e_p90": sorted(r["e2e_s"] for r in rows)[int(0.9 * (len(rows) - 1))],
        }
        points.append(point)
        print(f"[c={c:>3}] {requests_per_hour:8.0f} req/h | {point['box_seconds_per_request']:6.3f} "
              f"box-s/req | ${point['usd_per_1k_requests']:6.3f} per 1k | "
              f"ttft p50 {point['ttft_p50']:.2f}s p90 {point['ttft_p90']:.2f}s | "
              f"read {point['prompt_tokens_per_s']:7.0f} tok/s", flush=True)

    (out_dir / "trace.jsonl").write_text(
        "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in trace))
    summary = {
        "shape": {"input_tokens": in_tokens, "output_tokens": out_tokens},
        "model": model, "hourly_usd": hourly, "points": points,
        "instrument": "benchctl.perf_cell (stand-in for sglang.benchmark.serving)",
    }
    (out_dir / "cost.jsonl").write_text(
        "".join(json.dumps({"concurrency": p["concurrency"], "box_hour_usd": hourly,
                            "box_seconds_per_request": p["box_seconds_per_request"],
                            "usd_per_request_at_full_utilisation": p["usd_per_request"],
                            "utilisation_assumption": 1.0}, ensure_ascii=False) + "\n"
                for p in points))
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    return summary


def arrivals(url: str, model: str, prompt: str, out_tokens: int, *, rate_per_s: float,
             duration_s: float, seed: int, priority: int | None = None,
             max_inflight: int = 4096) -> dict:
    """Open-loop Poisson arrivals: submit at a fixed rate whatever the server is doing.

    Every measurement in this repository until now was closed loop — N requests in flight, a new one
    only when an old one returns — which measures capacity and cannot measure a service level. A closed
    loop is self-limiting: when the server slows, the offered load slows with it, so queueing never
    appears and latency looks like a constant. Real traffic arrives on its own schedule, and the whole
    question of whether there is slack for a second family to fill only exists below saturation.

    The generator's own honesty is reported rather than assumed: `achieved_rate_per_s` against the rate
    asked for, and `submit_lag_s`, the worst delay between when a request should have been sent and when
    it was. If either drifts, the number describes this loop and not the server.
    """
    rng = random.Random(seed)
    results: list[dict] = []
    lag = 0.0
    sent = 0
    started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=max_inflight) as pool:
        futures = []
        due = started
        while True:
            due += rng.expovariate(rate_per_s)
            if due - started >= duration_s:
                break
            now = time.perf_counter()
            if due > now:
                time.sleep(due - now)
            else:
                lag = max(lag, now - due)
            futures.append(pool.submit(_one, url, model, prompt, out_tokens, priority))
            sent += 1
        window = time.perf_counter() - started
        for f in futures:
            try:
                results.append(f.result())
            except Exception:
                pass
    wall = time.perf_counter() - started
    return {"sent": sent, "completed": len(results), "window_s": window, "wall_s": wall,
            "asked_rate_per_s": rate_per_s, "achieved_rate_per_s": sent / window if window else 0.0,
            "submit_lag_s": lag, "rows": results}


def _service_level(rows: list[dict], window_s: float, slo: float) -> dict:
    if not rows:
        return {"completed": 0, "within_slo": 0, "within_slo_frac": None,
                "slo_goodput_per_hour": 0.0, "ttft_p50": None, "ttft_p95": None, "ttft_p99": None}
    ttfts = sorted(r["ttft_s"] for r in rows)
    within = sum(1 for v in ttfts if v <= slo)
    at = lambda q: ttfts[min(len(ttfts) - 1, int(q * (len(ttfts) - 1)))]
    return {"completed": len(rows), "within_slo": within, "within_slo_frac": within / len(rows),
            "slo_goodput_per_hour": within / window_s * 3600,
            "completed_per_hour": len(rows) / window_s * 3600,
            "ttft_p50": statistics.median(ttfts), "ttft_p95": at(0.95), "ttft_p99": at(0.99)}


def run_arrival(out_dir: Path) -> dict:
    """The frontier below saturation: what long work costs when the short family is not filling the box.

    The closed-loop frontier answered a question about a full machine, where the answer is that a
    resident long request costs about a hundred short requests that would have met their deadline. That
    is the saturated end of the curve. This measures the other end, one arrival rate at a time, because
    the whole case for admitting a second family rests on box time nobody else wanted.
    """
    url, model = os.environ["PERF_URL"], os.environ["PERF_MODEL"]
    hourly = float(os.environ.get("HOURLY_USD", "15.2174"))
    slo = float(os.environ.get("SLO_TTFT_S", "1.0"))
    duration = float(os.environ.get("ARRIVAL_DURATION_S", "60"))
    seed = int(os.environ.get("SEED", "20260827"))
    rates = [float(x) for x in os.environ.get("ARRIVAL_RATES_PER_S", "6,18,30,42,54").split(",")]
    longs = [int(x) for x in os.environ.get("ARRIVAL_LONG_COUNTS", "0,1,2").split(",")]
    out_dir.mkdir(parents=True, exist_ok=True)

    words = [f"item{i}" for i in range(4096)]
    def prompt_of(n):
        return ("次の文章を読み、質問に答えてください。\n\n"
                + " ".join(words[i % len(words)] for i in range(max(1, n // 4)))
                + "\n\n質問: この文章の分類は A / B のどちらですか。")
    short, long_ = prompt_of(300), prompt_of(20000)

    cells = []
    for rate in rates:
        for L in longs:
            stop = False

            # Each thread returns its own count rather than incrementing a shared one: `x += 1` from
            # several threads can lose increments, and this number is reported.
            def long_stream() -> int:
                n = 0
                while not stop:
                    _one(url, model, salted(long_), 8)
                    n += 1
                return n

            bg = ThreadPoolExecutor(max_workers=max(1, L)) if L else None
            futures = []
            if bg:
                futures = [bg.submit(long_stream) for _ in range(L)]
                time.sleep(5)          # let the long work reach steady state before the clock starts
            a = arrivals(url, model, short, 8, rate_per_s=rate, duration_s=duration, seed=seed)
            stop = True
            long_done = 0
            if bg:
                long_done = sum(f.result() for f in futures)
                bg.shutdown(wait=True)
            sl = _service_level(a["rows"], a["window_s"], slo)
            long_per_hour = long_done / a["window_s"] * 3600 if a["window_s"] else 0.0
            cells.append({"asked_rate_per_s": rate, "long_resident": L,
                          "achieved_rate_per_s": a["achieved_rate_per_s"],
                          "submit_lag_s": a["submit_lag_s"], "sent": a["sent"],
                          "long_completions_per_hour": long_per_hour, **sl})
            print(f"  lambda={rate:>5.1f}/s L={L}: offered {a['achieved_rate_per_s']:5.1f}/s "
                  f"(lag {a['submit_lag_s']*1000:5.1f}ms)  goodput "
                  f"{sl['slo_goodput_per_hour']:>8,.0f}/h ({(sl['within_slo_frac'] or 0)*100:5.1f}% "
                  f"within {slo:.1f}s)  ttft p50 {sl['ttft_p50']:.2f}s p95 {sl['ttft_p95']:.2f}s "
                  f"p99 {sl['ttft_p99']:.2f}s  long {long_per_hour:>6.0f}/h", flush=True)

    summary = {"model": model, "hourly_usd": hourly, "slo_s": slo, "duration_s": duration,
               "seed": seed, "cells": cells,
               "instrument": "benchctl.perf_cell open-loop Poisson arrivals"}
    (out_dir / "arrival.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(f"[OK] wrote {out_dir}/arrival.json")
    return summary


def run_mix(out_dir: Path) -> dict:
    """What one long prefill does to the short requests sharing the machine with it.

    Every knee above was found with one shape in flight, and knees do not compose. A 20k prefill occupies
    the box for over a second, and while it does, short requests behind it wait — so a rule admitting both
    families at their own measured operating points can produce a machine that meets neither's latency.
    This measures the interference directly: the same short load, alone and with long work co-resident.
    """
    url, model = os.environ["PERF_URL"], os.environ["PERF_MODEL"]
    short_c = int(os.environ.get("MIX_SHORT_CONCURRENCY", "32"))
    long_c = int(os.environ.get("MIX_LONG_CONCURRENCY", "2"))
    rounds = int(os.environ.get("ROUNDS", "8"))
    out_dir.mkdir(parents=True, exist_ok=True)

    words = [f"item{i}" for i in range(4096)]
    def prompt_of(n):
        return ("次の文章を読み、質問に答えてください。\n\n"
                + " ".join(words[i % len(words)] for i in range(max(1, n // 4)))
                + "\n\n質問: この文章の分類は A / B のどちらですか。")
    short, long_ = prompt_of(300), prompt_of(20000)

    workers = int(os.environ.get("LOAD_WORKERS", "1"))
    # The service level the short family is held to. Average throughput and average value density are
    # both conserved when box time is reallocated between families, so neither can decide how much
    # long work to admit. What decides it is how many short requests still came back inside their
    # deadline -- goodput, not throughput.
    slo = float(os.environ.get("SLO_TTFT_S", "1.0"))
    # None means "send no priority field at all", which is required against an fcfs engine.
    prio_short = os.environ.get("MIX_SHORT_PRIORITY")
    prio_long = os.environ.get("MIX_LONG_PRIORITY")
    prio_short = int(prio_short) if prio_short not in (None, "") else None
    prio_long = int(prio_long) if prio_long not in (None, "") else None

    def short_load() -> dict:
        rows, wall = offer(url, model, short, 8, concurrency=short_c,
                           count=short_c * rounds, workers=workers, priority=prio_short)
        ttfts = sorted(r["ttft_s"] for r in rows)
        within = sum(1 for v in ttfts if v <= slo)
        return {"requests": len(rows), "wall_s": wall, "requests_per_hour": len(rows) / wall * 3600,
                "ttft_p50": statistics.median(ttfts),
                "ttft_p95": ttfts[min(len(ttfts) - 1, int(0.95 * (len(ttfts) - 1)))],
                "ttft_max": ttfts[-1],
                # Goodput, which is the only one of these that can decide how much long work to admit:
                # throughput and value density are both conserved when box time moves between families.
                "slo_s": slo, "within_slo": within, "within_slo_frac": within / len(rows),
                "slo_goodput_per_hour": within / wall * 3600}

    alone = short_load()
    print(f"[alone]  {alone['requests_per_hour']:.0f} req/h, goodput "
          f"{alone['slo_goodput_per_hour']:.0f}/h ({alone['within_slo_frac']*100:.1f}% within "
          f"{slo:.1f}s), ttft p50 {alone['ttft_p50']:.2f}s p95 {alone['ttft_p95']:.2f}s", flush=True)

    stop = False
    def long_stream():
        n = 0
        while not stop:
            _one(url, model, salted(long_), 8, prio_long)
            n += 1
        return n
    with ThreadPoolExecutor(max_workers=long_c) as bg:
        futures = [bg.submit(long_stream) for _ in range(long_c)]
        time.sleep(5)                       # let the long work reach steady state first
        mixed = short_load()
        stop = True
        long_done = sum(f.result() for f in futures)
    print(f"[mixed]  {mixed['requests_per_hour']:.0f} req/h, goodput "
          f"{mixed['slo_goodput_per_hour']:.0f}/h ({mixed['within_slo_frac']*100:.1f}% within "
          f"{slo:.1f}s), ttft p50 {mixed['ttft_p50']:.2f}s p95 {mixed['ttft_p95']:.2f}s "
          f"({long_done} long requests alongside)", flush=True)

    summary = {"model": model, "short_concurrency": short_c, "long_concurrency": long_c,
               "short_priority": prio_short, "long_priority": prio_long,
               "alone": alone, "mixed": mixed, "long_requests_completed": long_done,
               "short_throughput_ratio": mixed["requests_per_hour"] / alone["requests_per_hour"],
               "short_ttft_p95_ratio": mixed["ttft_p95"] / alone["ttft_p95"],
               "long_completions_per_hour": long_done / mixed["wall_s"] * 3600,
               # The frontier's two coordinates: what the short family still delivered on time, and
               # what the long family got served while it did.
               "slo_goodput_ratio": (mixed["slo_goodput_per_hour"] / alone["slo_goodput_per_hour"]
                                     if alone["slo_goodput_per_hour"] else None)}
    print(f"[cost of sharing] short throughput x{summary['short_throughput_ratio']:.2f}, "
          f"goodput x{summary['slo_goodput_ratio']:.2f}, ttft p95 "
          f"x{summary['short_ttft_p95_ratio']:.2f}, long {summary['long_completions_per_hour']:.0f}/h",
          flush=True)
    (out_dir / "mix.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    return summary


def run_grid(out_dir: Path) -> dict:
    """The shape grid: input length against output length, each at its own SLO-bounded knee.

    Input and output are swept separately and never collapsed into a token total. Reading is
    compute-bound and grows super-linearly with length; writing is bandwidth-bound, batches well, and the
    API charges about five times more for it. The two have different economics, so a curve in "tokens"
    would average two mechanisms that move in opposite directions.

    Only the box is measured here. What the API would have charged is computed afterwards from its own
    billed token counts, and quality is not overlaid on this: quality is a property of a family, not of a
    length, so the crossover is indexed by family and this grid only gives the shape of the curve.
    """
    url, model = os.environ["PERF_URL"], os.environ["PERF_MODEL"]
    hourly = float(os.environ.get("HOURLY_USD", "15.2174"))
    rounds = int(os.environ.get("ROUNDS", "3"))
    slo = float(os.environ.get("TTFT_P95_SLO", "30"))
    ins = [int(x) for x in os.environ.get("INPUT_GRID", "300,1000,3000,8000,20000").split(",")]
    outs = [int(x) for x in os.environ.get("OUTPUT_GRID", "8,256").split(",")]
    out_dir.mkdir(parents=True, exist_ok=True)

    words = [f"item{i}" for i in range(4096)]
    grid = []
    for in_tokens in ins:
        prompt = ("次の文章を読み、質問に答えてください。\n\n"
                  + " ".join(words[i % len(words)] for i in range(max(1, in_tokens // 4)))
                  + "\n\n質問: この文章の分類は A / B のどちらですか。")
        for out_tokens in outs:
            print(f"[shape] in~{in_tokens} out={out_tokens}", flush=True)
            points = sustainable_knee(
                url, model, prompt, out_tokens, hourly, rounds=rounds, ttft_p95_slo=slo,
                patience=int(os.environ.get("PATIENCE", "1")),
                ladder=tuple(int(x) for x in os.environ.get(
                    "LADDER", "1,2,4,8,16,32,64,128").split(",")))
            within = [p for p in points if p["within_slo"]] or points[:1]
            knee = max(within, key=lambda p: p["requests_per_hour"])
            grid.append({"asked_input_tokens": in_tokens, "output_tokens": out_tokens,
                         "knee": knee, "ladder": points})
            print(f"    -> knee c={knee['concurrency']} {knee['requests_per_hour']:.0f} req/h, "
                  f"{knee['box_seconds_per_request']:.4f} box-s/req, "
                  f"read {knee['prompt_tokens_per_s']:.0f} tok/s, "
                  f"write {knee['completion_tokens_per_s']:.0f} tok/s", flush=True)

    summary = {"model": model, "hourly_usd": hourly, "ttft_p95_slo": slo, "grid": grid,
               "instrument": "benchctl.perf_cell grid (stand-in for sglang.benchmark.serving)"}
    (out_dir / "grid.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(f"[OK] wrote {out_dir}/grid.json")
    return summary


if __name__ == "__main__":
    target = Path(os.environ.get("OUT_DIR", "/artifacts/perf"))
    mode = os.environ.get("MODE", "single")
    if mode == "grid":
        run_grid(target)
    elif mode == "mix":
        run_mix(target)
    elif mode == "arrival":
        run_arrival(target)
    else:
        run_perf_cell(target)
