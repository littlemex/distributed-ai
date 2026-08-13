"""Unit tests for perf aggregation and noise floor."""
from __future__ import annotations

import pytest

from . import perf as P


def test_latency_percentiles_monotonic():
    pct = P.latency_percentiles([10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
    assert pct["p50"] <= pct["p90"] <= pct["p99"]
    assert abs(pct["p50"] - 55.0) < 1e-9  # midpoint of 1..100 linear-interp


def test_latency_percentiles_single_sample():
    pct = P.latency_percentiles([42.0])
    assert pct["p50"] == pct["p90"] == pct["p99"] == 42.0


def test_latency_percentiles_empty_raises():
    with pytest.raises(ValueError):
        P.latency_percentiles([])


def test_throughput():
    t = P.throughput(total_tokens=10000, elapsed_s=2.0, num_requests=50)
    assert t["tokens_per_s"] == 5000.0 and t["requests_per_s"] == 25.0
    with pytest.raises(ValueError):
        P.throughput(1, 0, 1)


def test_noise_floor_multi_run():
    nf = P.noise_floor([[100, 100, 100, 400], [100, 100, 100, 420]])
    assert nf["runs"] == 2
    assert nf["p99_over_p50_ratio_max"] is not None and nf["p99_over_p50_ratio_max"] >= 1.0


def test_noise_floor_no_runs():
    nf = P.noise_floor([])
    assert nf["runs"] == 0 and nf["p99_over_p50_ratio_max"] is None


def test_build_perf_assembles_block():
    block = P.build_perf([10, 20, 30], total_tokens=300, elapsed_s=1.0, num_requests=3,
                         noise=P.noise_floor([[10, 20, 30]]))
    assert set(block) == {"latency_ms", "throughput", "noise_floor"}
    assert block["throughput"]["tokens_per_s"] == 300.0
    assert block["noise_floor"]["runs"] == 1
