"""Unit tests for the crash-safe trace finalizer, using moto to mock S3 with real boto3 calls.

A companion real-S3 round-trip (against a temporary bucket) is run out-of-band for real-machine
verification; these tests cover the logic and failure modes deterministically.
"""
from __future__ import annotations

import os

import boto3
import pytest
from botocore.exceptions import ClientError
from moto import mock_aws

from . import finalizer as F

BUCKET = "test-mcp-traces"
REGION = "us-east-1"


@pytest.fixture
def s3():
    with mock_aws():
        client = boto3.client("s3", region_name=REGION)
        client.create_bucket(Bucket=BUCKET)
        yield client


def _write_trace(dir_, name, data=b"fake-nsys-trace-bytes" * 1000):
    tmp = os.path.join(dir_, name + ".tmp")
    with open(tmp, "wb") as f:
        f.write(data)
    return tmp


def test_finalize_local_atomic_and_marker(tmp_path):
    d = str(tmp_path)
    tmp = _write_trace(d, "trace.ncu-rep")
    final = os.path.join(d, "trace.ncu-rep")
    digest = F.finalize_local(tmp, final)
    assert not os.path.exists(tmp)  # renamed away
    assert os.path.exists(final)
    assert os.path.exists(final + F.DONE_SUFFIX)
    assert digest.startswith("sha256:")
    assert open(final + F.DONE_SUFFIX).read().strip() == digest


def test_upload_finalized_verifies_and_receipts(s3, tmp_path):
    d = str(tmp_path)
    final = os.path.join(d, "trace.ncu-rep")
    F.finalize_local(_write_trace(d, "trace.ncu-rep"), final)
    res = F.upload_finalized(s3, final, BUCKET, "exp/case/run/trace.ncu-rep")
    assert res["uri"] == f"s3://{BUCKET}/exp/case/run/trace.ncu-rep"
    assert res["sha256"].startswith("sha256:")
    # object + its sha256 sidecar exist in S3
    assert s3.head_object(Bucket=BUCKET, Key="exp/case/run/trace.ncu-rep")["ContentLength"] > 0
    assert s3.get_object(Bucket=BUCKET, Key="exp/case/run/trace.ncu-rep.sha256")["Body"].read().decode() == res["sha256"]
    # local receipt written
    assert os.path.exists(final + F.UPLOADED_SUFFIX)


def test_upload_refuses_unfinalized(s3, tmp_path):
    d = str(tmp_path)
    # a trace with NO DONE marker must not be uploaded (fail-closed)
    final = os.path.join(d, "trace.ncu-rep")
    with open(final, "wb") as f:
        f.write(b"partial")
    with pytest.raises(ValueError, match="no DONE marker"):
        F.upload_finalized(s3, final, BUCKET, "k")


def test_upload_retries_then_succeeds(s3, tmp_path):
    d = str(tmp_path)
    final = os.path.join(d, "t")
    F.finalize_local(_write_trace(d, "t"), final)

    calls = {"n": 0}
    real_upload = s3.upload_file

    def flaky_upload(path, bucket, key, **kwargs):
        calls["n"] += 1
        if calls["n"] < 3:
            raise RuntimeError("transient network error")
        return real_upload(path, bucket, key, **kwargs)

    s3.upload_file = flaky_upload
    res = F.upload_finalized(s3, final, BUCKET, "k/t", base_delay_s=0, _sleep=lambda *_: None)
    assert res["attempts"] == 3 and calls["n"] == 3


def test_upload_fails_closed_after_retries(s3, tmp_path):
    d = str(tmp_path)
    final = os.path.join(d, "t")
    F.finalize_local(_write_trace(d, "t"), final)
    s3.upload_file = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("perma-fail"))
    with pytest.raises(RuntimeError, match="failed after"):
        F.upload_finalized(s3, final, BUCKET, "k/t", max_attempts=3, base_delay_s=0, _sleep=lambda *_: None)
    assert not os.path.exists(final + F.UPLOADED_SUFFIX)  # no receipt on failure


def test_access_denied_is_not_retried(s3, tmp_path):
    d = str(tmp_path)
    final = os.path.join(d, "t")
    F.finalize_local(_write_trace(d, "t"), final)
    calls = {"n": 0}

    def denied(*a, **k):
        calls["n"] += 1
        raise ClientError({"Error": {"Code": "AccessDenied", "Message": "no"}}, "PutObject")

    s3.upload_file = denied
    with pytest.raises(ClientError):
        F.upload_finalized(s3, final, BUCKET, "k", max_attempts=5, base_delay_s=0, _sleep=lambda *_: None)
    assert calls["n"] == 1  # permission error fails immediately, does NOT re-send the GB file


def test_sweep_skips_already_quarantined(s3, tmp_path):
    d = str(tmp_path)
    final = os.path.join(d, "t")
    F.finalize_local(_write_trace(d, "t"), final)
    open(final + F.QUARANTINE_SUFFIX, "w").close()  # pre-quarantined
    res = F.sweep(s3, d, BUCKET, key_for=lambda p: "k")
    assert res["uploaded"] == [] and final in res["skipped_quarantined"]


def test_sweep_recovers_crashed_producer(s3, tmp_path):
    d = str(tmp_path)
    # two finalized-but-unuploaded traces (as if the producer died before upload)
    for name in ("runA/trace", "runB/trace"):
        os.makedirs(os.path.join(d, os.path.dirname(name)), exist_ok=True)
        F.finalize_local(_write_trace(d, name), os.path.join(d, name))
    res = F.sweep(s3, d, BUCKET, key_for=lambda p: "recovered/" + os.path.relpath(p, d))
    assert len(res["uploaded"]) == 2 and res["quarantined"] == []
    assert s3.head_object(Bucket=BUCKET, Key="recovered/runA/trace")["ContentLength"] > 0


def test_sweep_quarantines_on_failure_never_deletes(s3, tmp_path):
    d = str(tmp_path)
    final = os.path.join(d, "trace")
    F.finalize_local(_write_trace(d, "trace"), final)
    s3.upload_file = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("perma-fail"))
    res = F.sweep(s3, d, BUCKET, key_for=lambda p: "k")
    assert res["uploaded"] == [] and final in res["quarantined"]
    assert os.path.exists(final)  # trace NOT deleted
    assert os.path.exists(final + ".QUARANTINE")
