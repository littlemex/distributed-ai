"""Real round-trip test of the MLflow logging convention against a local file store.

Uses ``file://<tmp>/mlruns`` as the tracking URI — a genuine MLflow backend (no server, no
network), so this exercises the actual mlflow client, tag/metric logging, and read-back. Skips
cleanly if mlflow is not installed.
"""
from __future__ import annotations

import pytest

from . import report as R
from . import mlflow_log as ML

mlflow = pytest.importorskip("mlflow")


def _sample_report(**overrides):
    rep = R.build_run_report(
        run_id="local-ignored",  # MLflow assigns the real id; this field is unused by the logger
        experiment_id="exp-nemotron-h-2026-09",
        case_id="nemotron_h_engine_cb/bs64_in2048_out128",
        stage="engine_cb",
        verdict="pass",
        metrics={"cosine": 0.9993, "max_abs_error": 0.0012, "token_match_rate": 0.998},
        thresholds={"cosine_min": 0.99},
        reference=R.make_side("golden", "fp32"),
        target=R.make_side(
            "trn2-vllm-plugin", "bf16", software_fingerprint={"torch": "2.8.0"},
            hardware=R.hardware_fingerprint("neuron", "trn2.3xlarge", "ap-southeast-4",
                                            capacity_type="reserved", tenant="perfcost-neuron"),
        ),
        golden_hash="sha256:abc123",
        perf={"latency_ms": {"p50": 371, "p90": 405, "p99": 412},
              "throughput": {"tokens_per_s": 4633.0, "requests_per_s": 36.19},
              "noise_floor": {}},
        perf_verdict="pass",
        experiment_alias="H3 tokyo-vs-melbourne",
        experiment_note="first neuron capture",
    )
    rep.update(overrides)
    return rep


def test_log_run_roundtrip(tmp_path):
    uri = f"file://{tmp_path}/mlruns"
    run_id = ML.log_run(_sample_report(), profile_uri="s3://b/exp/case/run/trace.ntff",
                        profile_sha256="sha256:deadbeef", tracking_uri=uri)
    assert run_id

    client = mlflow.tracking.MlflowClient(tracking_uri=uri)
    run = client.get_run(run_id)
    # tags round-tripped
    assert run.data.tags["accelerator"] == "neuron"
    assert run.data.tags["case_id"].startswith("nemotron_h_engine_cb/")
    assert run.data.tags["golden_hash"] == "sha256:abc123"
    assert run.data.tags["region"] == "ap-southeast-4"
    assert run.data.tags["profile_uri"] == "s3://b/exp/case/run/trace.ntff"
    assert run.data.tags["profile_sha256"] == "sha256:deadbeef"
    # metrics round-tripped (accuracy + perf)
    assert abs(run.data.metrics["cosine"] - 0.9993) < 1e-9
    assert abs(run.data.metrics["latency_p99_ms"] - 412) < 1e-9
    assert abs(run.data.metrics["tokens_per_s"] - 4633.0) < 1e-9
    # experiment created under the given name
    exp = client.get_experiment(run.info.experiment_id)
    assert exp.name == "exp-nemotron-h-2026-09"


def test_search_runs_cross_accelerator(tmp_path):
    """Two runs (gpu + neuron) sharing (experiment, case, golden) are queryable — the
    cross-accelerator comparison mechanism (no custom store)."""
    uri = f"file://{tmp_path}/mlruns"
    common = dict(profile_sha256="sha256:x", tracking_uri=uri)
    ML.log_run(_sample_report(
        target=R.make_side("vllm", "fp8", hardware=R.hardware_fingerprint("gpu", "g6e.4xlarge", "ap-northeast-1")),
    ), profile_uri="s3://b/gpu/trace.ncu-rep", **common)
    ML.log_run(_sample_report(), profile_uri="s3://b/neuron/trace.ntff", **common)  # neuron

    mlflow.set_tracking_uri(uri)
    exp = mlflow.get_experiment_by_name("exp-nemotron-h-2026-09")
    df = mlflow.search_runs(
        [exp.experiment_id],
        filter_string="tags.golden_hash = 'sha256:abc123'",
    )
    accels = set(df["tags.accelerator"])
    assert accels == {"gpu", "neuron"}


def test_missing_mandatory_tag_raises(tmp_path):
    rep = _sample_report()
    rep["golden_hash"] = None  # drop a mandatory identity field
    with pytest.raises(ValueError, match="mandatory tags"):
        ML.log_run(rep, profile_uri="s3://b/t", profile_sha256="sha256:x",
                   tracking_uri=f"file://{tmp_path}/mlruns")


def test_missing_profile_uri_raises_when_profiled(tmp_path):
    with pytest.raises(ValueError, match="mandatory tags"):
        ML.log_run(_sample_report(), profile_uri="", profile_sha256="sha256:x",
                   tracking_uri=f"file://{tmp_path}/mlruns")


def test_accuracy_only_run_without_trace(tmp_path):
    # profiled=False: a run with no profiler trace is allowed (accuracy-only)
    run_id = ML.log_run(_sample_report(), profiled=False, tracking_uri=f"file://{tmp_path}/mlruns")
    client = mlflow.tracking.MlflowClient(tracking_uri=f"file://{tmp_path}/mlruns")
    assert client.get_run(run_id).data.tags["profile_uri"] == "none"


def test_log_run_is_idempotent(tmp_path):
    # a retry after an upload-succeeded/log-failed crash must not create a duplicate run
    uri = f"file://{tmp_path}/mlruns"
    common = dict(profile_uri="s3://b/t", profile_sha256="sha256:same", tracking_uri=uri)
    r1 = ML.log_run(_sample_report(), **common)
    r2 = ML.log_run(_sample_report(), **common)
    assert r1 == r2


def test_run_id_written_back_and_report_persisted(tmp_path):
    uri = f"file://{tmp_path}/mlruns"
    rep = _sample_report()
    run_id = ML.log_run(rep, profile_uri="s3://b/t", profile_sha256="sha256:z", tracking_uri=uri)
    assert rep["run_id"] == run_id  # MLflow's id written back into the report
    client = mlflow.tracking.MlflowClient(tracking_uri=uri)
    artifacts = [a.path for a in client.list_artifacts(run_id)]
    assert "run_report.json" in artifacts  # the run record is persisted for the offline join
