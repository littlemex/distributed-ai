"""Unit tests for verdict judging (accuracy, perf, parity, trend)."""
from __future__ import annotations

import json
import os

from . import verdict as V


def test_judge_accuracy_pass_and_fail():
    v, fails = V.judge({"cosine": 0.999, "max_abs_error": 0.001},
                       {"cosine_min": 0.99, "max_abs_error_max": 0.01})
    assert v == "pass" and fails == []
    v, fails = V.judge({"cosine": 0.90}, {"cosine_min": 0.99})
    assert v == "fail" and len(fails) == 1


def test_judge_missing_metric_fails_closed():
    # threshold present but metric absent -> FAIL (a gate must not pass on a missing metric)
    v, fails = V.judge({"cosine": 0.999}, {"token_match_rate_min": 0.99})
    assert v == "fail" and any("missing" in f for f in fails)
    # opt-in: allow_missing skips absent metrics
    v2, _ = V.judge({"cosine": 0.999}, {"token_match_rate_min": 0.99}, allow_missing=True)
    assert v2 == "pass"


def test_judge_nan_fails_closed():
    v, fails = V.judge({"cosine": float("nan")}, {"cosine_min": 0.99})
    assert v == "fail" and any("non-finite" in f or "missing" in f for f in fails)


def test_judge_bool_is_not_a_metric():
    # bool must not be treated as 1.0/0.0 and slip through
    v, fails = V.judge({"cosine": True}, {"cosine_min": 0.99})
    assert v == "fail"


def test_judge_perf_latency_and_throughput():
    perf = {"latency_ms": {"p50": 100, "p99": 400}, "throughput": {"tokens_per_s": 5000, "requests_per_s": 40}}
    v, fails = V.judge_perf(perf, {"latency_p99_ms_max": 500, "tokens_per_s_min": 4000})
    assert v == "pass" and fails == []
    v, fails = V.judge_perf(perf, {"latency_p99_ms_max": 300, "tokens_per_s_min": 6000})
    assert v == "fail" and len(fails) == 2


def test_judge_perf_missing_fails_closed():
    # a threshold with no corresponding perf value must FAIL, not silently pass
    v, fails = V.judge_perf({"latency_ms": {}, "throughput": {}}, {"latency_p50_ms_max": 10})
    assert v == "fail" and any("missing" in f for f in fails)
    # no thresholds -> nothing to judge -> pass
    v2, fails2 = V.judge_perf({"latency_ms": {}, "throughput": {}}, {})
    assert v2 == "pass" and fails2 == []


def test_judge_parity_relative_degradation():
    ref = {"cosine": 0.999, "token_match_rate": 1.0, "rel_error_p99": 0.01}
    # target close enough -> pass
    tgt_ok = {"cosine": 0.998, "token_match_rate": 0.99, "rel_error_p99": 0.012}
    v, fails = V.judge_parity(ref, tgt_ok,
                              {"cosine_parity_eps": 0.005, "token_match_parity_eps": 0.02,
                               "rel_error_p99_parity_ratio": 1.5})
    assert v == "pass" and fails == []
    # target degrades too much -> fail on cosine + token
    tgt_bad = {"cosine": 0.98, "token_match_rate": 0.90, "rel_error_p99": 0.05}
    v, fails = V.judge_parity(ref, tgt_bad,
                              {"cosine_parity_eps": 0.005, "token_match_parity_eps": 0.02,
                               "rel_error_p99_parity_ratio": 1.5})
    assert v == "fail" and len(fails) == 3


def test_trend_alert_schema_version_isolation(tmp_path):
    d = str(tmp_path)
    # a v1 series (declining) and a v2 series (stable) for the same case
    for i, c in enumerate([0.99, 0.95, 0.90]):
        json.dump({"schema_version": "1", "case_id": "c", "metrics": {"cosine": c}},
                  open(os.path.join(d, f"v1_{i}.json"), "w"))
    for i, c in enumerate([0.999, 0.999, 0.999]):
        json.dump({"schema_version": "2", "case_id": "c", "metrics": {"cosine": c}},
                  open(os.path.join(d, f"v2_{i}.json"), "w"))
    # keyed to v2: current 0.999 vs stable v2 history -> no alert
    res_v2 = V.trend_alert("c", 0.999, d, schema_version="2")
    assert res_v2["alert"] is False
    # keyed to v1: current 0.85 vs declining v1 history -> alert
    res_v1 = V.trend_alert("c", 0.85, d, schema_version="1")
    assert res_v1["alert"] is True


def test_trend_alert_insufficient_history(tmp_path):
    res = V.trend_alert("c", 0.99, str(tmp_path), schema_version="2")
    assert res["alert"] is False and "insufficient" in res["reason"]
