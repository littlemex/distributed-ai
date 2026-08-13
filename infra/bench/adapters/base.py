"""Shared last mile for every ETL adapter.

An adapter's job is tool-specific: turn one measurement tool's output into a
:func:`report.build_run_report` dict + a finalized trace file. Everything after that is common,
so it lives here: upload the trace to our S3 (crash-safe, verified) and log the MLflow run that
references it. This keeps per-tool adapters tiny and guarantees all runs share the same identity
and storage contract regardless of which tool produced them.
"""
from __future__ import annotations

from typing import Any

from harness import mlflow_log
from storage import finalizer


def publish_run(
    report: dict[str, Any],
    final_trace_path: str,
    s3_client: Any,
    trace_bucket: str,
    trace_key: str,
    small_artifacts: list[str] | None = None,
    tracking_uri: str | None = None,
) -> str:
    """Upload the finalized trace to our S3, then log the MLflow run referencing it.

    ``final_trace_path`` must already be finalized (``finalize_local`` wrote its DONE marker).
    Returns the MLflow-assigned run id. Order matters:
      1. **preflight** the run identity BEFORE the expensive upload, so a programming error
         (missing golden_hash/region/...) fails fast instead of after a GB transfer;
      2. upload + verify (fail-closed: no MLflow run if the upload cannot be verified);
      3. log the MLflow run (idempotent; writes run_id back + persists run_report.json).
    """
    mlflow_log.preflight(report, profiled=True)
    uploaded = finalizer.upload_finalized(s3_client, final_trace_path, trace_bucket, trace_key)
    return mlflow_log.log_run(
        report,
        profile_uri=uploaded["uri"],
        profile_sha256=uploaded["sha256"],
        small_artifacts=small_artifacts,
        tracking_uri=tracking_uri,
    )
