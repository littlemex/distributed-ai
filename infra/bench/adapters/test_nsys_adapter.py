"""End-to-end adapter test: nsys measurement -> S3 (moto) + MLflow (file store).

Exercises the whole ETL last mile: build the report from measured values, finalize + upload the
trace, log the MLflow run referencing it, and read the run back to confirm identity + metrics.
"""
from __future__ import annotations

import os

import boto3
import pytest
from moto import mock_aws

from adapters import base, nsys_adapter
from storage import finalizer

mlflow = pytest.importorskip("mlflow")

BUCKET = "test-mcp-traces"


@pytest.fixture
def s3():
    with mock_aws():
        c = boto3.client("s3", region_name="us-east-1")
        c.create_bucket(Bucket=BUCKET)
        yield c


def test_nsys_adapter_end_to_end(s3, tmp_path):
    # a finalized fake nsys trace
    tmp = os.path.join(str(tmp_path), "trace.nsys-rep.tmp")
    with open(tmp, "wb") as f:
        f.write(b"nsys-rep-bytes" * 500)
    final = os.path.join(str(tmp_path), "trace.nsys-rep")
    finalizer.finalize_local(tmp, final)

    rep = nsys_adapter.build_gpu_run_report(
        experiment_id="exp-gpu-vs-neuron",
        case_id="llama_ffn/bs32",
        stage="engine",
        golden_hash="sha256:g",
        instance_type="g6e.4xlarge",
        region="ap-northeast-1",
        impl="vllm-openai:v0.20.0",
        dtype="fp8",
        accuracy_metrics={"cosine": 0.9999, "token_match_rate": 1.0},
        accuracy_verdict="pass",
        latency_samples_ms=[100, 110, 120, 130, 140],
        total_tokens=6000,
        elapsed_s=1.2,
        num_requests=5,
        software_fingerprint={"torch": "2.8.0", "transformers": "4.55.0"},  # captured at measure time
        perf_verdict="pass",
        capacity_type="on-demand",
        tenant="perfcost-gpu",
    )

    uri = f"file://{tmp_path}/mlruns"
    run_id = base.publish_run(rep, final, s3, BUCKET, "exp/case/run/trace.nsys-rep", tracking_uri=uri)
    assert run_id

    # trace really in S3
    assert s3.head_object(Bucket=BUCKET, Key="exp/case/run/trace.nsys-rep")["ContentLength"] > 0
    # MLflow run has the identity + perf metrics, and profile_uri points at our S3 (not an artifact)
    client = mlflow.tracking.MlflowClient(tracking_uri=uri)
    run = client.get_run(run_id)
    assert run.data.tags["accelerator"] == "gpu"
    assert run.data.tags["profile_uri"] == f"s3://{BUCKET}/exp/case/run/trace.nsys-rep"
    assert run.data.tags["instance_type"] == "g6e.4xlarge"
    assert run.data.metrics["tokens_per_s"] == pytest.approx(5000.0)
    assert "latency_p50_ms" in run.data.metrics
