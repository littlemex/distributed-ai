"""Unit tests for the v2 report schema helpers."""
from __future__ import annotations

import json

import pytest

from . import report as R


def test_schema_version_is_2():
    assert R.SCHEMA_VERSION == "2"


def test_hardware_fingerprint_drops_none_and_validates():
    hw = R.hardware_fingerprint("gpu", "g6e.4xlarge", "ap-northeast-1")
    assert hw == {"accelerator": "gpu", "instance_type": "g6e.4xlarge", "region": "ap-northeast-1"}
    hw2 = R.hardware_fingerprint("neuron", "trn2.3xlarge", "ap-southeast-4",
                                 capacity_type="reserved", tenant="perfcost-neuron")
    assert hw2["capacity_type"] == "reserved" and hw2["tenant"] == "perfcost-neuron"
    with pytest.raises(ValueError):
        R.hardware_fingerprint("tpu", "x", "y")


def test_make_side_merges_hardware_into_fingerprint():
    side = R.make_side("vllm", "fp8", "0.20.0",
                       software_fingerprint={"torch": "2.8.0"},
                       hardware=R.hardware_fingerprint("gpu", "g6e.4xlarge", "ap-northeast-1"))
    assert side["fingerprint"]["torch"] == "2.8.0"
    assert side["fingerprint"]["accelerator"] == "gpu"
    assert side["impl"] == "vllm" and side["dtype"] == "fp8"


def test_build_run_report_shape():
    rep = R.build_run_report(
        run_id="r1", experiment_id="exp1", case_id="c/1", stage="engine", verdict="pass",
        metrics={"cosine": 0.999}, thresholds={"cosine_min": 0.99},
        reference=R.make_side("golden", "fp32"),
        target=R.make_side("neuron", "bf16", hardware=R.hardware_fingerprint("neuron", "trn2.3xlarge", "ap-southeast-4")),
        golden_hash="sha256:abc",
        profile_ref=R.artifact_ref("s3://b/trace.ntff", "sha256:def", kind="neuron-profile"),
        window=R.make_window("ip-1", 1000.0, 1060.0),
        experiment_alias="H3 tokyo-vs-melb", experiment_note="first try",
        timestamp_jst="2026-08-13T18:00:00+09:00",
    )
    assert rep["kind"] == "run" and rep["schema_version"] == "2"
    assert rep["run_id"] == "r1" and rep["experiment_id"] == "exp1"
    assert rep["experiment_alias"] == "H3 tokyo-vs-melb" and rep["experiment_note"] == "first try"
    assert rep["perf"] is None and rep["perf_verdict"] is None
    assert rep["profile_ref"]["sha256"] == "sha256:def"
    assert rep["window"]["start_epoch"] == 1000.0
    # JSON-serializable
    json.loads(json.dumps(rep))


def test_build_comparison_report_shape():
    cmp = R.build_comparison_report(
        experiment_id="exp1", case_id="c/1", golden_hash="sha256:abc",
        reference_run_id="rgpu", target_run_id="rneuron",
        reference_run="s3://reports/gpu.json", target_run="s3://reports/neuron.json",
        accuracy_parity_verdict="pass", perf_verdict="fail",
        deltas={"perf": {"latency_p50_ratio": 1.3}},
    )
    assert cmp["kind"] == "comparison"
    assert cmp["reference_run_id"] == "rgpu" and cmp["target_run_id"] == "rneuron"
    assert cmp["accuracy_parity_verdict"] == "pass" and cmp["perf_verdict"] == "fail"


def test_build_report_shim_is_backward_compatible():
    rep = R.build_report("c/1", "layer", "pass", {"cosine": 1.0}, {"cosine_min": 0.99},
                         R.make_side("golden", "fp32"), R.make_side("neuron", "bf16"))
    assert rep["kind"] == "run" and rep["schema_version"] == "2"
    # experiment_id defaults to case_id, run_id auto-generated
    assert rep["experiment_id"] == "c/1" and rep["run_id"]


def test_comparison_from_runs_enforces_same_golden():
    gpu = R.build_run_report(run_id="rg", experiment_id="e", case_id="c", stage="s", verdict="pass",
                             metrics={}, thresholds={}, reference=R.make_side("golden", "fp32"),
                             target=R.make_side("vllm", "fp8"), golden_hash="sha256:A")
    neu = R.build_run_report(run_id="rn", experiment_id="e", case_id="c", stage="s", verdict="pass",
                             metrics={}, thresholds={}, reference=R.make_side("golden", "fp32"),
                             target=R.make_side("neuron", "bf16"), golden_hash="sha256:A")
    cmp = R.comparison_from_runs(gpu, neu, reference_uri="s3://r/g.json", target_uri="s3://r/n.json",
                                 accuracy_parity_verdict="pass", perf_verdict="pass", deltas={})
    assert cmp["kind"] == "comparison" and cmp["reference_run_id"] == "rg"
    # different golden -> refused
    neu_bad = dict(neu, golden_hash="sha256:B")
    with pytest.raises(ValueError, match="golden_hash mismatch"):
        R.comparison_from_runs(gpu, neu_bad, reference_uri="s3://r/g.json", target_uri="s3://r/n.json",
                               accuracy_parity_verdict="pass", perf_verdict="pass", deltas={})


def test_new_run_id_unique():
    assert R.new_run_id() != R.new_run_id()


def test_environment_fingerprint_has_core_keys():
    fp = R.environment_fingerprint()
    assert "python" in fp and "platform" in fp and "env" in fp
