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

import json
import multiprocessing
import os
import statistics
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def _one(url: str, model: str, prompt: str, max_tokens: int) -> dict:
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "stream": True,
        "stream_options": {"include_usage": True},
    }).encode()
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
        return list(pool.map(lambda _: _one(_JOB["url"], _JOB["model"], _JOB["prompt"],
                                            _JOB["out_tokens"]), range(count)))


def _init(job: dict) -> None:
    _JOB.update(job)


def offer(url: str, model: str, prompt: str, out_tokens: int, *, concurrency: int, count: int,
          workers: int) -> tuple[list[dict], float]:
    """Offer `count` requests with `concurrency` in flight, spread over `workers` processes."""
    workers = max(1, min(workers, concurrency))
    per = [(concurrency // workers + (1 if i < concurrency % workers else 0)) for i in range(workers)]
    shares = [(threads, count * threads // concurrency) for threads in per]
    job = {"url": url, "model": model, "prompt": prompt, "out_tokens": out_tokens}
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
            rows = list(pool.map(lambda _: _one(url, model, prompt, out_tokens), range(c * rounds)))
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

    def short_load() -> dict:
        rows, wall = offer(url, model, short, 8, concurrency=short_c,
                           count=short_c * rounds, workers=workers)
        ttfts = sorted(r["ttft_s"] for r in rows)
        return {"requests": len(rows), "wall_s": wall, "requests_per_hour": len(rows) / wall * 3600,
                "ttft_p50": statistics.median(ttfts),
                "ttft_p95": ttfts[min(len(ttfts) - 1, int(0.95 * (len(ttfts) - 1)))],
                "ttft_max": ttfts[-1]}

    alone = short_load()
    print(f"[alone]  {alone['requests_per_hour']:.0f} req/h, ttft p50 {alone['ttft_p50']:.2f}s "
          f"p95 {alone['ttft_p95']:.2f}s max {alone['ttft_max']:.2f}s", flush=True)

    stop = False
    def long_stream():
        n = 0
        while not stop:
            _one(url, model, long_, 8)
            n += 1
        return n
    with ThreadPoolExecutor(max_workers=long_c) as bg:
        futures = [bg.submit(long_stream) for _ in range(long_c)]
        time.sleep(5)                       # let the long work reach steady state first
        mixed = short_load()
        stop = True
        long_done = sum(f.result() for f in futures)
    print(f"[mixed]  {mixed['requests_per_hour']:.0f} req/h, ttft p50 {mixed['ttft_p50']:.2f}s "
          f"p95 {mixed['ttft_p95']:.2f}s max {mixed['ttft_max']:.2f}s "
          f"({long_done} long requests alongside)", flush=True)

    summary = {"model": model, "short_concurrency": short_c, "long_concurrency": long_c,
               "alone": alone, "mixed": mixed, "long_requests_completed": long_done,
               "short_throughput_ratio": mixed["requests_per_hour"] / alone["requests_per_hour"],
               "short_ttft_p95_ratio": mixed["ttft_p95"] / alone["ttft_p95"]}
    print(f"[cost of sharing] short throughput x{summary['short_throughput_ratio']:.2f}, "
          f"short ttft p95 x{summary['short_ttft_p95_ratio']:.2f}", flush=True)
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
    else:
        run_perf_cell(target)
