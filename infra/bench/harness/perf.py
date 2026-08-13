"""Performance aggregation — device-independent, like ``metrics.py`` for accuracy.

Turns raw latency samples + throughput counters into the ``perf`` block of a run report, and
derives a noise floor from repeated runs so ``verdict.judge_perf`` can threshold against
measured variance rather than an arbitrary constant (same philosophy as the accuracy noise
floor). Pure functions over plain numbers; no torch, no K8s, no chip knowledge.
"""
from __future__ import annotations

from typing import Any


def _percentile(sorted_vals: list[float], q: float) -> float:
    """Linear-interpolated percentile. ``q`` in [0, 1]. Assumes ``sorted_vals`` is sorted and
    non-empty."""
    if not sorted_vals:
        raise ValueError("percentile of empty sequence")
    if len(sorted_vals) == 1:
        return float(sorted_vals[0])
    pos = q * (len(sorted_vals) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(sorted_vals) - 1)
    frac = pos - lo
    return float(sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac)


def latency_percentiles(samples_ms: list[float]) -> dict[str, float]:
    """p50/p90/p99 of per-request latency in milliseconds."""
    if not samples_ms:
        raise ValueError("latency_percentiles requires at least one sample")
    s = sorted(float(x) for x in samples_ms)
    return {
        "p50": _percentile(s, 0.50),
        "p90": _percentile(s, 0.90),
        "p99": _percentile(s, 0.99),
    }


def throughput(total_tokens: int, elapsed_s: float, num_requests: int) -> dict[str, float]:
    """Aggregate throughput. ``elapsed_s`` must be > 0."""
    if elapsed_s <= 0:
        raise ValueError("elapsed_s must be positive")
    return {
        "tokens_per_s": float(total_tokens) / elapsed_s,
        "requests_per_s": float(num_requests) / elapsed_s,
    }


def noise_floor(run_latencies_ms: list[list[float]], source: str = "multi-run variance") -> dict[str, Any]:
    """Derive a noise floor from N repeated runs of the same case.

    Returns the worst (max across runs) p99/p50 ratio, which ``judge_perf`` uses as the tolerance
    band: a real regression must exceed the run-to-run jitter to count. Needs >= 2 runs to be
    meaningful; with fewer it reports ``ratio=None`` and ``runs`` so the caller can refuse to
    threshold on noise it never measured.
    """
    ratios: list[float] = []
    for samples in run_latencies_ms:
        pct = latency_percentiles(samples)
        p50 = pct["p50"]
        if p50 > 0:
            ratios.append(pct["p99"] / p50)
    ratio_max = max(ratios) if ratios else None
    return {
        "source": source,
        "runs": len(run_latencies_ms),
        "p99_over_p50_ratio_max": ratio_max,
    }


def build_perf(
    latency_samples_ms: list[float],
    total_tokens: int,
    elapsed_s: float,
    num_requests: int,
    noise: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Assemble the ``perf`` block written into a run report (report.py §perf)."""
    return {
        "latency_ms": latency_percentiles(latency_samples_ms),
        "throughput": throughput(total_tokens, elapsed_s, num_requests),
        "noise_floor": noise or {},
    }
