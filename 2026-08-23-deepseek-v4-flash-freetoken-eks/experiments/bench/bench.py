#!/usr/bin/env python3
"""Measure FreeToken serving latency and throughput over the OpenAI-compatible streaming API.

Run in-cluster by experiments/bench/run_bench.sh so the client is not the bottleneck and the
numbers describe the engine rather than the path to it. Standard library only, so the bench pod
starts immediately instead of spending a minute on pip.

What is measured, and why these and not "requests/sec":

* **TTFT** (time to first token) -- for an offload engine this is dominated by prefill plus
  whatever expert fetches the prompt's routing triggers, so it is the metric most sensitive to a
  cold expert cache.
* **TPOT** (time per output token, steady state) -- the inter-token gap after the first token,
  i.e. what a user perceives as generation speed. Reported as its reciprocal too (decode tok/s).
* **Output throughput** -- SUM of output tokens across all concurrent streams divided by
  wall-clock. This is the number that scales with concurrency, and it diverges from per-stream
  tok/s exactly when expert-cache thrash starts to bite.

TTFT and TPOT are separated deliberately: a single "tokens/sec" figure that folds in prefill hides
whether a slow result is a prefill problem or a decode problem, and for MoE offload those have
completely different causes (PCIe fetch on miss vs prompt length).

Cache-hit context is captured from /v1/cache/status before and after each sweep point, because a
throughput number for an offload backend is close to meaningless without it.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request

PROMPT = (
    "Explain, in detail, how a mixture-of-experts transformer routes tokens to experts, "
    "and why expert offloading to host memory changes the performance profile of decoding. "
    "Cover the memory hierarchy involved and the role of the PCIe bus."
)


def _get(base: str, path: str, timeout: float = 30.0):
    try:
        with urllib.request.urlopen(f"{base}{path}", timeout=timeout) as r:
            return json.loads(r.read().decode())
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as exc:
        return {"error": str(exc)}


class Result:
    __slots__ = ("ttft", "tpot", "out_tokens", "wall", "error")

    def __init__(self):
        self.ttft = None
        self.tpot = None
        self.out_tokens = 0
        self.wall = 0.0
        self.error = None


def stream_once(base: str, model: str, max_tokens: int, timeout: float) -> Result:
    """One streaming completion. Token timestamps come from SSE chunk arrivals."""
    res = Result()
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": PROMPT}],
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "stream": True,
    }).encode()
    req = urllib.request.Request(
        f"{base}/v1/chat/completions", data=body,
        headers={"Content-Type": "application/json"},
    )
    t0 = time.perf_counter()
    stamps: list[float] = []
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    chunk = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                delta = (chunk.get("choices") or [{}])[0].get("delta") or {}
                # Count BOTH channels. Reasoning models stream their chain of thought as
                # `reasoning_content` and emit `content` only at the end, so a content-only counter
                # measures zero tokens for a model like gpt-oss and silently reports no throughput
                # while the GPU is fully busy. Decode cost is identical either way, which is what a
                # tokens/sec figure is supposed to capture.
                if delta.get("content") or delta.get("reasoning_content"):
                    stamps.append(time.perf_counter())
    except Exception as exc:  # noqa: BLE001 - any transport failure is a failed sample
        res.error = f"{type(exc).__name__}: {exc}"

    res.wall = time.perf_counter() - t0
    res.out_tokens = len(stamps)
    if stamps:
        res.ttft = stamps[0] - t0
        if len(stamps) > 1:
            # Steady-state only: exclude the first gap, which is prefill, not decode.
            res.tpot = (stamps[-1] - stamps[0]) / (len(stamps) - 1)
    return res


def sweep(base: str, model: str, conc: int, max_tokens: int, timeout: float) -> dict:
    results: list[Result] = []
    lock = threading.Lock()

    def worker():
        r = stream_once(base, model, max_tokens, timeout)
        with lock:
            results.append(r)

    cache_before = _get(base, "/v1/cache/status")
    threads = [threading.Thread(target=worker) for _ in range(conc)]
    t0 = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.perf_counter() - t0
    cache_after = _get(base, "/v1/cache/status")

    ok = [r for r in results if r.error is None and r.out_tokens > 0]
    failed = [r for r in results if r.error is not None]
    total_out = sum(r.out_tokens for r in ok)
    ttfts = [r.ttft for r in ok if r.ttft is not None]
    tpots = [r.tpot for r in ok if r.tpot is not None]

    def pct(xs, q):
        if not xs:
            return None
        s = sorted(xs)
        return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]

    return {
        "concurrency": conc,
        "requests_ok": len(ok),
        "requests_failed": len(failed),
        "errors": sorted({r.error for r in failed})[:3],
        "wall_s": round(wall, 3),
        "output_tokens_total": total_out,
        # THE throughput number: aggregate output tokens per second of wall clock.
        "output_tok_per_s": round(total_out / wall, 2) if wall > 0 else None,
        "per_stream_tok_per_s": round(total_out / wall / conc, 2) if wall > 0 and conc else None,
        "ttft_ms_p50": round(pct(ttfts, 0.50) * 1000, 1) if ttfts else None,
        "ttft_ms_p95": round(pct(ttfts, 0.95) * 1000, 1) if ttfts else None,
        "tpot_ms_mean": round(statistics.fmean(tpots) * 1000, 2) if tpots else None,
        "decode_tok_per_s_per_stream": round(1.0 / statistics.fmean(tpots), 2) if tpots else None,
        "cache_before": cache_before,
        "cache_after": cache_after,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://freetoken-serving:1919")
    ap.add_argument("--model", default=None, help="defaults to the first id from /v1/models")
    ap.add_argument("--concurrency", default="1,2,4",
                    help="comma-separated sweep points")
    ap.add_argument("--max-tokens", type=int, default=128)
    ap.add_argument("--timeout", type=float, default=900.0)
    ap.add_argument("--warmup", type=int, default=1,
                    help="discarded requests first; the expert cache and JIT kernels are cold")
    args = ap.parse_args()

    models = _get(args.base, "/v1/models")
    ids = [m.get("id") for m in (models.get("data") or [])] if isinstance(models, dict) else []
    model = args.model or (ids[0] if ids else None)
    if not model:
        print(f"[bench][FAIL] could not resolve a model from /v1/models: {models}", file=sys.stderr)
        return 1
    print(f"[bench] base={args.base} model={model}")

    # Cold-start effects are real and large here (first-use JIT compile, empty expert cache), so
    # they are measured out rather than silently averaged in.
    for i in range(args.warmup):
        w = stream_once(args.base, model, min(32, args.max_tokens), args.timeout)
        print(f"[bench] warmup {i+1}/{args.warmup}: {w.out_tokens} tok in {w.wall:.1f}s"
              + (f" ERROR {w.error}" if w.error else ""))

    points = [int(x) for x in args.concurrency.split(",") if x.strip()]
    out = {"model": model, "max_tokens": args.max_tokens, "sweep": []}
    for c in points:
        print(f"[bench] concurrency={c} ...", flush=True)
        r = sweep(args.base, model, c, args.max_tokens, args.timeout)
        out["sweep"].append(r)
        print(f"[bench]   ok={r['requests_ok']} failed={r['requests_failed']} "
              f"out_tok={r['output_tokens_total']} "
              f"throughput={r['output_tok_per_s']} tok/s "
              f"ttft_p50={r['ttft_ms_p50']} ms tpot={r['tpot_ms_mean']} ms "
              f"decode/stream={r['decode_tok_per_s_per_stream']} tok/s", flush=True)

    print("\n=== RESULTS (markdown) ===")
    print("| concurrency | ok/failed | output tok/s | per-stream tok/s | TTFT p50 ms | TTFT p95 ms | TPOT ms | decode tok/s/stream |")
    print("|---|---|---|---|---|---|---|---|")
    for r in out["sweep"]:
        print(f"| {r['concurrency']} | {r['requests_ok']}/{r['requests_failed']} "
              f"| {r['output_tok_per_s']} | {r['per_stream_tok_per_s']} "
              f"| {r['ttft_ms_p50']} | {r['ttft_ms_p95']} | {r['tpot_ms_mean']} "
              f"| {r['decode_tok_per_s_per_stream']} |")

    print("\n=== RAW JSON ===")
    print(json.dumps(out, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
