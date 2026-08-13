"""Threshold judgment + regression detection (two tiers: threshold breach + trend degradation).

Thresholds are not arbitrary; they are derived from the noise floor (the caller passes values
computed from the fp32 vs fp64 reference difference). Trend degradation flags a monotonic decline
in the cosine series across past reports, even while still within threshold.
"""
from __future__ import annotations

import glob
import json
import math
import os
from typing import Any


def _finite_number(v: Any) -> float | None:
    """Return v as a float only if it is a real, finite number. bool is rejected (it is an int
    subclass and must never be treated as a metric); NaN/Inf are rejected so they cannot slip
    through a ``<``/``>`` comparison as a silent pass (the classic gate fail-open)."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    f = float(v)
    return f if math.isfinite(f) else None


def judge(metrics: dict[str, Any], thresholds: dict[str, Any],
          allow_missing: bool = False) -> tuple[str, list[str]]:
    """Whether metrics satisfy thresholds. Also returns the list of reasons that failed.

    Fail-closed: for every threshold whose metric is missing or not a finite number, the verdict
    FAILS (a gate must never pass because a metric was absent or NaN). Set ``allow_missing=True``
    only for stages where a metric legitimately does not apply.

    Threshold keys: cosine_min, max_abs_error_max, rel_error_p99_max, token_match_rate_min,
    expert_set_agreement_min.
    """
    fails: list[str] = []

    def check(mkey, tkey, comparator, symbol):
        if tkey not in thresholds:
            return
        v = _finite_number(metrics.get(mkey))
        if v is None:
            if not allow_missing:
                fails.append(f"{mkey}: missing or non-finite (threshold {tkey} set)")
            return
        if comparator(v, thresholds[tkey]):
            fails.append(f"{mkey}={v:.6g} {symbol} {thresholds[tkey]}")

    check("cosine", "cosine_min", lambda v, t: v < t, "<")
    check("max_abs_error", "max_abs_error_max", lambda v, t: v > t, ">")
    check("rel_error_p99", "rel_error_p99_max", lambda v, t: v > t, ">")
    check("token_match_rate", "token_match_rate_min", lambda v, t: v < t, "<")
    check("expert_set_agreement", "expert_set_agreement_min", lambda v, t: v < t, "<")

    return ("pass" if not fails else "fail"), fails


def judge_perf(perf: dict[str, Any], thresholds: dict[str, Any]) -> tuple[str, list[str]]:
    """Whether a perf block satisfies its thresholds. Device-neutral: only reads the common
    latency/throughput view (accelerator-specific detail never drives a verdict).

    Example threshold keys:
      latency_p50_ms_max, latency_p99_ms_max, tokens_per_s_min, requests_per_s_min
    Only judges keys present in both ``perf`` and ``thresholds`` (like :func:`judge`).
    """
    fails: list[str] = []
    latency = (perf or {}).get("latency_ms", {}) or {}
    tput = (perf or {}).get("throughput", {}) or {}

    def check(raw, tkey, label, comparator, symbol):
        if tkey not in thresholds:
            return
        v = _finite_number(raw)
        if v is None:
            fails.append(f"{label}: missing or non-finite (threshold {tkey} set)")
            return
        if comparator(v, thresholds[tkey]):
            fails.append(f"{label}={v:.6g} {symbol} {thresholds[tkey]}")

    check(latency.get("p50"), "latency_p50_ms_max", "latency_p50_ms", lambda v, t: v > t, ">")
    check(latency.get("p99"), "latency_p99_ms_max", "latency_p99_ms", lambda v, t: v > t, ">")
    check(tput.get("tokens_per_s"), "tokens_per_s_min", "tokens_per_s", lambda v, t: v < t, "<")
    check(tput.get("requests_per_s"), "requests_per_s_min", "requests_per_s", lambda v, t: v < t, "<")

    return ("pass" if not fails else "fail"), fails


def judge_parity(
    ref_metrics: dict[str, Any], tgt_metrics: dict[str, Any], thresholds: dict[str, Any]
) -> tuple[str, list[str]]:
    """Cross-accelerator parity verdict (join step only).

    Both sides were measured against the *same* golden (asserted via ``golden_hash`` upstream),
    so parity checks how much the target degrades *relative to the reference*, not absolute
    quality. A regression is real only if it exceeds the allowed slack.

    Threshold keys (all optional; only present ones are judged):
      cosine_parity_eps          target cosine must be >= reference cosine - eps
      token_match_parity_eps     target token_match_rate must be >= reference - eps
      rel_error_p99_parity_ratio target rel_error_p99 must be <= reference * ratio
    """
    fails: list[str] = []

    def _get(d, k):
        return _finite_number((d or {}).get(k))

    def worse_min(key, tkey, label):
        r, t = _get(ref_metrics, key), _get(tgt_metrics, key)
        if tkey in thresholds and r is not None and t is not None and t < r - thresholds[tkey]:
            fails.append(f"{label}: target {t:.6g} < reference {r:.6g} - {thresholds[tkey]}")

    def worse_ratio_max(key, tkey, label):
        r, t = _get(ref_metrics, key), _get(tgt_metrics, key)
        if tkey in thresholds and r is not None and t is not None and t > r * thresholds[tkey]:
            fails.append(f"{label}: target {t:.6g} > reference {r:.6g} * {thresholds[tkey]}")

    worse_min("cosine", "cosine_parity_eps", "cosine")
    worse_min("token_match_rate", "token_match_parity_eps", "token_match_rate")
    worse_ratio_max("rel_error_p99", "rel_error_p99_parity_ratio", "rel_error_p99")

    return ("pass" if not fails else "fail"), fails


def trend_alert(case_id: str, current_cosine: float, history_dir: str,
                degrade_eps: float = 1e-6, window: int = 5,
                schema_version: str | None = None) -> dict[str, Any]:
    """Detect trend degradation over the cosine series of past reports.

    alert=True if it is monotonically degrading even while within threshold. Assumes history_dir
    holds accumulated past report JSONs.

    History is keyed on ``(schema_version, case_id)`` when ``schema_version`` is given, so a v1
    accuracy series and a v2 series for the same case never mix (the two shapes are not
    comparable). Passing ``schema_version=None`` keeps the legacy case_id-only behaviour.
    """
    reports = []
    for p in sorted(glob.glob(os.path.join(history_dir, "*.json"))):
        try:
            r = json.load(open(p))
            if r.get("case_id") != case_id:
                continue
            if schema_version is not None and r.get("schema_version") != schema_version:
                continue
            if r.get("metrics", {}).get("cosine") is not None:
                reports.append((p, r["metrics"]["cosine"]))
        except Exception:  # noqa: BLE001
            continue
    series = [c for _, c in reports][-window:] + [current_cosine]
    if len(series) < 3:
        return {"alert": False, "reason": "insufficient history", "series_len": len(series)}
    # monotonic degradation (latest is worse than the past mean by more than degrade_eps)
    prev_mean = sum(series[:-1]) / len(series[:-1])
    degrading = current_cosine < prev_mean - degrade_eps
    return {
        "alert": bool(degrading),
        "current": current_cosine,
        "prev_mean": prev_mean,
        "series_len": len(series),
    }
