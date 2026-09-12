"""What a cached prompt token costs the box, so its ledger can stop charging for work the engine skipped.

The asymmetry this exists to close. An API layer's cost is computed from four counts the provider reports, and
a cache read is billed at a tenth of fresh input — so when an API serves a prefix from cache, the ledger sees
it. The box's cost is computed as `prompt_tokens x input_usd_per_mtok`, one rate for every prompt token
whether the engine computed it or read it from the prefix cache. On the cache-ablation run the box served
**72.5%** of its prompt tokens from cache and was charged full price for all of them.

That runs against the box, so every published box result is pessimistic by whatever this measures, which is
the safe direction for a conclusion and the wrong number for a comparison. Closing it needs a rate, and a rate
has to be measured rather than assumed: "a cache hit is free" is not true, because the tokens still have to be
attended to, and "a cache hit costs nothing to prefill" is not the same claim as "it costs nothing".

## How the rate is derived

The box's existing input rate is not a price anyone charges; it is an hourly machine cost divided by measured
prefill throughput:

    input_usd_per_mtok = (hourly_usd / 3600) / prefill_tokens_per_second x 1e6

$15.2174/h over 17,947 tok/s gives $0.2355, which is the $0.236 in the specs. So a cached-token rate is the
same arithmetic over a *cached* prefill throughput, and the whole problem reduces to measuring that.

Which is done by timing, not by trusting a counter. For a request with one output token, latency is almost
entirely prefill, and it is linear in the number of tokens prefilled:

    latency(n) = overhead + n / throughput

Fitting that line over a sweep of prompt sizes separates the per-token cost from the fixed cost of a request,
and doing it twice — once where the prefix misses and once where the same prefix hits — gives both
throughputs from the same instrument. A single pair of requests could not: at one size, the difference between
a hit and a miss is confounded with everything constant in a request.

## Two things that would quietly ruin it

**The router.** Two replicas sit behind one Service, so a repeat can land on the replica that does not hold
the prefix and come back a miss. A run that averaged those in would report a cached throughput somewhere
between the two arms and call it measurement. So the engine's own `cached_tokens` is read on every reply and a
repeat only counts as a hit if it actually was one; the fraction that had to be discarded is reported.

**The first request of the sweep.** vLLM's first request after a change in shape pays for graph capture and
allocator warm-up. Every size is therefore requested once as a discarded warm-up before either arm is timed.
"""

from __future__ import annotations

import argparse
import json
import statistics
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field

# One token-ish word repeated. The text is uninteresting on purpose: the measurement is of prefill length, and
# anything with structure invites the engine to spend differently at different sizes.
_FILLER = "reference "


@dataclass
class Sample:
    prompt_tokens: int
    cached_tokens: int
    latency_s: float

    @property
    def cached_share(self) -> float:
        return (self.cached_tokens / self.prompt_tokens) if self.prompt_tokens else 0.0


@dataclass
class Arm:
    name: str
    samples: list[Sample] = field(default_factory=list)

    def fit(self) -> tuple[float, float, int]:
        """Least squares on latency against prompt tokens: returns (overhead_s, tokens_per_second, n)."""
        points = [(s.prompt_tokens, s.latency_s) for s in self.samples]
        if len(points) < 2:
            return (0.0, 0.0, len(points))
        mean_x = statistics.fmean(x for x, _ in points)
        mean_y = statistics.fmean(y for _, y in points)
        sxx = sum((x - mean_x) ** 2 for x, _ in points)
        sxy = sum((x - mean_x) * (y - mean_y) for x, y in points)
        if sxx == 0 or sxy <= 0:
            return (mean_y, 0.0, len(points))
        slope = sxy / sxx                       # seconds per token
        return (mean_y - slope * mean_x, 1.0 / slope, len(points))


def _post(url: str, body: dict, timeout: float = 900.0) -> tuple[dict, float]:
    request = urllib.request.Request(url, data=json.dumps(body).encode(),
                                     headers={"content-type": "application/json"})
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=timeout) as reply:
        payload = json.loads(reply.read())
    return payload, time.perf_counter() - started


def _ask(url: str, model: str, prompt: str) -> Sample:
    payload, latency = _post(url, {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        # One token out, so latency is prefill plus one decode step rather than a generation.
        "max_tokens": 1,
        "temperature": 0.0,
    })
    usage = payload.get("usage") or {}
    details = usage.get("prompt_tokens_details") or {}
    return Sample(prompt_tokens=int(usage.get("prompt_tokens") or 0),
                  cached_tokens=int(details.get("cached_tokens") or 0),
                  latency_s=latency)


def measure(url: str, model: str, sizes: tuple[int, ...], *, repeats: int = 3,
            hit_threshold: float = 0.9) -> dict:
    """Sweep prompt sizes, timing a missing prefix and a hitting one at each."""
    miss, hit = Arm("miss"), Arm("hit")
    discarded = 0
    for words in sizes:
        # A prefix unique to this size, so the miss arm really misses and the sizes do not seed each other.
        prompt = f"[size {words}] " + _FILLER * words + "\nReply with the single word OK."
        _ask(url, model, prompt)                    # warm-up, timed but discarded
        fresh_prompt = f"[size {words} fresh] " + _FILLER * words + "\nReply with the single word OK."
        sample = _ask(url, model, fresh_prompt)
        if sample.cached_share < 0.5:
            miss.samples.append(sample)
        else:
            # The warm-up seeded a shared prefix after all; a "miss" that hit is not a miss.
            discarded += 1
        for _ in range(repeats):
            sample = _ask(url, model, prompt)
            if sample.cached_share >= hit_threshold:
                hit.samples.append(sample)
            else:
                # Landed on the replica without the prefix. Averaging this in would report a throughput
                # somewhere between the two arms and call it a measurement.
                discarded += 1
        print(f"  {words:7d} words -> miss n={len(miss.samples):2d} hit n={len(hit.samples):3d} "
              f"discarded {discarded}", flush=True)

    miss_overhead, miss_thr, miss_n = miss.fit()
    hit_overhead, hit_thr, hit_n = hit.fit()
    return {
        "miss": {"overhead_s": miss_overhead, "tokens_per_second": miss_thr, "n": miss_n,
                 "samples": [vars(s) for s in miss.samples]},
        "hit": {"overhead_s": hit_overhead, "tokens_per_second": hit_thr, "n": hit_n,
                "samples": [vars(s) for s in hit.samples]},
        "discarded_samples": discarded,
    }


def rates(result: dict, hourly_usd: float) -> dict:
    """The two per-token rates the box's ledger needs, from the two throughputs."""
    per_second = hourly_usd / 3600.0

    def usd_per_mtok(throughput: float) -> float | None:
        return (per_second / throughput * 1e6) if throughput > 0 else None

    fresh = usd_per_mtok(result["miss"]["tokens_per_second"])
    cached = usd_per_mtok(result["hit"]["tokens_per_second"])
    return {
        "hourly_usd": hourly_usd,
        "input_usd_per_mtok": fresh,
        "cache_read_usd_per_mtok": cached,
        "cached_is_cheaper_by": (fresh / cached) if (fresh and cached) else None,
    }


def measure_aggregate(url: str, model: str, sizes: tuple[int, ...], *, concurrency: int,
                      hit_threshold: float = 0.9) -> dict:
    """Aggregate prefill throughput with `concurrency` requests in flight, for a missing and a hitting prefix.

    The serial sweep above measures a single stream, and the box's published input rate does not: $0.236 per
    Mtok comes from 17,947 tok/s "aggregate at 16 in flight". Those are different quantities — a single stream
    cannot fill the machine — so a cached rate derived from a serial measurement would be divided by the wrong
    number, and a ratio taken between the two bases would silently compare a busy machine with an idle one.

    So both arms are measured the way the existing rate was: C requests issued together, wall clock over the
    batch, aggregate tokens per second. The hit arm shares one prefix across all C requests, which is the
    shape that makes prefix caching worth having — many conversations against one system prompt.
    """
    from concurrent.futures import ThreadPoolExecutor

    out: dict[str, dict] = {}
    for arm in ("miss", "hit"):
        rows = []
        for words in sizes:
            shared = f"[agg {words}] " + _FILLER * words + "\nReply with the single word OK."
            if arm == "hit":
                _ask(url, model, shared)                     # seed the prefix, then time the batch
            prompts = ([shared] * concurrency if arm == "hit" else
                       [f"[agg {words} lane {i}] " + _FILLER * words + "\nReply with the single word OK."
                        for i in range(concurrency)])
            started = time.perf_counter()
            with ThreadPoolExecutor(max_workers=concurrency) as pool:
                samples = list(pool.map(lambda p: _ask(url, model, p), prompts))
            wall = time.perf_counter() - started
            tokens = sum(s.prompt_tokens for s in samples)
            cached = sum(s.cached_tokens for s in samples)
            share = (cached / tokens) if tokens else 0.0
            usable = (share >= hit_threshold) if arm == "hit" else (share < 0.5)
            rows.append({"words": words, "prompt_tokens": tokens, "cached_tokens": cached,
                         "cached_share": share, "wall_s": wall,
                         "tokens_per_second": tokens / wall if wall else 0.0, "usable": usable})
            print(f"  {arm:4} {words:7d} words x{concurrency}: {tokens:9,d} tok in {wall:6.2f}s = "
                  f"{tokens / wall if wall else 0:9,.0f} tok/s  cached {share:5.1%}"
                  f"{'' if usable else '   [discarded]'}", flush=True)
        usable_rows = [r for r in rows if r["usable"]]
        # The machine's ceiling, not an average: throughput rises with prefill length until the batch is
        # compute-bound, and the rate the ledger wants is the one at the shape it runs.
        best = max((r["tokens_per_second"] for r in usable_rows), default=0.0)
        out[arm] = {"rows": rows, "tokens_per_second": best, "n_usable": len(usable_rows)}
    return out


def decompose(aggregate: dict, hourly_usd: float) -> dict:
    """Separate the cached token's own cost out of a batch that was only mostly cached.

    The hit arm never reaches 100%: at 16 lanes racing to populate one prefix, and with the cache working in
    blocks, the best batch measured was 91.5% cached. Its throughput is therefore a blend, and quoting the
    blend as "what a cached token costs" charges the cached tokens for the fresh ones in the same batch.

    The fresh throughput is measured independently in the same run, so the blend can be solved instead of
    accepted:

        wall = fresh_tokens / fresh_throughput + cached_tokens / cached_throughput

    Everything but `cached_throughput` is measured, so it falls out. This makes the box look better, which is
    why the blended figure is reported next to it rather than replaced by it.
    """
    fresh_thr = aggregate["miss"]["tokens_per_second"]
    rows = [r for r in aggregate["hit"]["rows"] if r["usable"]]
    if not (fresh_thr > 0 and rows):
        return {}
    per_second = hourly_usd / 3600.0
    out = []
    for row in rows:
        cached, total, wall = row["cached_tokens"], row["prompt_tokens"], row["wall_s"]
        fresh = total - cached
        fresh_seconds = fresh / fresh_thr
        cached_seconds = wall - fresh_seconds
        if cached <= 0 or cached_seconds <= 0:
            continue
        thr = cached / cached_seconds
        out.append({"words": row["words"], "cached_share": row["cached_share"],
                    "cached_tokens_per_second": thr,
                    "cache_read_usd_per_mtok": per_second / thr * 1e6})
    if not out:
        return {}
    # The most-cached batch is the least contaminated one, so it is the estimate rather than a mean.
    best = max(out, key=lambda r: r["cached_share"])
    return {"per_size": out, "estimate": best,
            "blended_cache_read_usd_per_mtok": per_second / rows[-1]["tokens_per_second"] * 1e6}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--hourly-usd", type=float, required=True)
    ap.add_argument("--sizes", type=int, nargs="+",
                    default=[500, 2000, 5000, 10000, 20000, 40000])
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--concurrency", type=int, default=0,
                    help="also measure aggregate throughput with this many in flight, which is the basis "
                         "the box's published input rate was derived on")
    ap.add_argument("--out", default=None)
    args = ap.parse_args(argv)

    print(f"sweeping {args.sizes} words against {args.url}")
    result = measure(args.url, args.model, tuple(args.sizes), repeats=args.repeats)
    derived = rates(result, args.hourly_usd)

    aggregate = None
    if args.concurrency:
        print(f"\naggregate, {args.concurrency} in flight — the basis the published rate uses:")
        aggregate = measure_aggregate(args.url, args.model, tuple(args.sizes),
                                      concurrency=args.concurrency)
        derived_aggregate = rates(aggregate, args.hourly_usd)
        aggregate["derived"] = derived_aggregate
        print(f"\n  miss {aggregate['miss']['tokens_per_second']:,.0f} tok/s -> "
              f"${derived_aggregate['input_usd_per_mtok']:.4f} / Mtok")
        print(f"  hit  {aggregate['hit']['tokens_per_second']:,.0f} tok/s -> "
              f"${derived_aggregate['cache_read_usd_per_mtok']:.4f} / Mtok")
        if derived_aggregate["cached_is_cheaper_by"]:
            print(f"  a cached token costs {1 / derived_aggregate['cached_is_cheaper_by']:.1%} of a fresh "
                  f"one at this concurrency ({derived_aggregate['cached_is_cheaper_by']:.1f}x cheaper)")
        split = decompose(aggregate, args.hourly_usd)
        aggregate["decomposed"] = split
        if split:
            e = split["estimate"]
            fresh_rate = derived_aggregate["input_usd_per_mtok"]
            print(f"  the hit arm was {e['cached_share']:.1%} cached, so the blend above charges cached "
                  f"tokens for the fresh ones beside them. Solving the blend:")
            print(f"    cached prefill {e['cached_tokens_per_second']:,.0f} tok/s -> "
                  f"${e['cache_read_usd_per_mtok']:.4f} / Mtok, "
                  f"{e['cache_read_usd_per_mtok'] / fresh_rate:.1%} of a fresh token")

    for arm in ("miss", "hit"):
        a = result[arm]
        print(f"\n{arm:5}: {a['n']:3d} samples, overhead {a['overhead_s']:.3f}s, "
              f"{a['tokens_per_second']:,.0f} prefill tok/s")
    print(f"\ndiscarded {result['discarded_samples']} samples that landed the wrong way")
    print(f"\nat ${args.hourly_usd}/h:")
    print(f"  fresh prompt tokens  ${derived['input_usd_per_mtok']:.4f} / Mtok"
          if derived["input_usd_per_mtok"] else "  fresh: not measurable")
    print(f"  cached prompt tokens ${derived['cache_read_usd_per_mtok']:.4f} / Mtok"
          if derived["cache_read_usd_per_mtok"] else "  cached: not measurable")
    if derived["cached_is_cheaper_by"]:
        print(f"  a cached token costs {1 / derived['cached_is_cheaper_by']:.1%} of a fresh one "
              f"({derived['cached_is_cheaper_by']:.1f}x cheaper)")
    if args.out:
        with open(args.out, "w") as handle:
            json.dump({"serial": {"measured": result, "derived": derived},
                       "aggregate": aggregate, "concurrency": args.concurrency}, handle, indent=2)
        print(f"\n[OK] wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
