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


if __name__ == "__main__":
    run_perf_cell(Path(os.environ.get("OUT_DIR", "/artifacts/perf")))
