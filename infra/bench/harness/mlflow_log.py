"""The thin, shared logging convention over managed MLflow.

This is the one part of experiment management we standardize: every profiling run — no matter
which measurement tool produced it (Nsight, neuron-profile, or any OSS tool, absorbed by an ETL
adapter) — is logged to MLflow with a *mandatory identity* so GPU (one region) and Neuron
(another) runs land in the same framework and can be analyzed together later.

MLflow (the SageMaker managed MLflow App) is the ID authority: it assigns the run_id, which we
write back into the report and persist as a small ``run_report.json`` artifact so the offline
comparison join can reference runs. We keep the GB trace OUT of MLflow artifacts (200 MB
download limit) — it lives in our own S3 and is referenced by ``profile_uri``/``profile_sha256``.

Logging is idempotent: a deterministic ``idempotency_key`` tag lets a retry (after an
upload-succeeded / log-failed crash) find the existing run instead of creating a duplicate.

Note: ``report["experiment_id"]`` is used as the MLflow *experiment name* (``set_experiment``
takes a name); MLflow's own numeric experiment_id is separate.
"""
from __future__ import annotations

import hashlib
import math
from typing import Any

# Identity tags always required (a run without these is not analyzable — fail loudly).
CORE_TAGS = ("experiment_id", "accelerator", "case_id", "stage", "golden_hash",
             "region", "instance_type", "accuracy_verdict")
# Additionally required only when the run carries a profiler trace (profiled=True).
PROFILE_TAGS = ("profile_uri", "profile_sha256")

OPTIONAL_TAGS = ("capacity_type", "tenant", "perf_verdict", "experiment_alias", "impl", "dtype")

_ACCURACY_METRIC_KEYS = ("cosine", "max_abs_error", "mean_abs_error", "rel_error_p99",
                         "rel_error_max", "token_match_rate", "expert_set_agreement")

_TAG_VALUE_MAXLEN = 4900  # MLflow tag value limit is ~5000 chars; truncate to stay safely under


def _import_mlflow():
    import mlflow

    return mlflow


def _finite(v: Any) -> float | None:
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    f = float(v)
    return f if math.isfinite(f) else None


def idempotency_key(report: dict[str, Any], profile_sha256: str) -> str:
    """Deterministic key over the run's identity, so a retried log finds the existing run."""
    tf = (report.get("target") or {}).get("fingerprint", {}) or {}
    parts = [str(report.get("experiment_id")), str(report.get("case_id")), str(report.get("stage")),
             str(tf.get("accelerator")), str(report.get("golden_hash")), str(profile_sha256)]
    return hashlib.sha256("\x1f".join(parts).encode()).hexdigest()


def tags_from_report(report: dict[str, Any], profile_uri: str, profile_sha256: str) -> dict[str, str]:
    """Derive the MLflow tag set from a run-report dict + the trace pointer (hardware identity is
    read from ``target.fingerprint``)."""
    if report.get("schema_version") != "2":
        raise ValueError(f"unsupported report schema_version: {report.get('schema_version')!r}")
    tf = (report.get("target") or {}).get("fingerprint", {}) or {}
    tags: dict[str, Any] = {
        "experiment_id": report.get("experiment_id"),
        "accelerator": tf.get("accelerator"),
        "case_id": report.get("case_id"),
        "stage": report.get("stage"),
        "golden_hash": report.get("golden_hash"),
        "region": tf.get("region"),
        "instance_type": tf.get("instance_type"),
        "capacity_type": tf.get("capacity_type"),
        "tenant": tf.get("tenant"),
        "accuracy_verdict": report.get("verdict"),
        "perf_verdict": report.get("perf_verdict"),
        "experiment_alias": report.get("experiment_alias"),
        "impl": (report.get("target") or {}).get("impl"),
        "dtype": (report.get("target") or {}).get("dtype"),
        "profile_uri": profile_uri or None,
        "profile_sha256": profile_sha256 or None,
    }
    return {k: str(v)[:_TAG_VALUE_MAXLEN] for k, v in tags.items() if v is not None}


def metrics_from_report(report: dict[str, Any]) -> dict[str, float]:
    """Numeric metrics: accuracy + perf. Non-finite / bool values are dropped (never logged as a
    misleading 1.0 or a query-breaking NaN)."""
    out: dict[str, float] = {}
    for k in _ACCURACY_METRIC_KEYS:
        v = _finite((report.get("metrics") or {}).get(k))
        if v is not None:
            out[k] = v
    perf = report.get("perf") or {}
    for pk in ("p50", "p90", "p99"):
        v = _finite((perf.get("latency_ms") or {}).get(pk))
        if v is not None:
            out[f"latency_{pk}_ms"] = v
    for tk in ("tokens_per_s", "requests_per_s"):
        v = _finite((perf.get("throughput") or {}).get(tk))
        if v is not None:
            out[tk] = v
    w = report.get("window") or {}
    for wk in ("start_epoch", "end_epoch"):
        v = _finite(w.get(wk))
        if v is not None:
            out[f"window_{wk}"] = v
    return out


def validate_tags(tags: dict[str, str], profiled: bool = True) -> None:
    required = CORE_TAGS + (PROFILE_TAGS if profiled else ())
    missing = [t for t in required if not tags.get(t)]
    if missing:
        raise ValueError(f"run is not analyzable — missing mandatory tags: {missing}")


def preflight(report: dict[str, Any], profiled: bool = True) -> None:
    """Validate identity BEFORE the caller uploads a GB trace, so a programming error fails fast
    instead of after an expensive upload (profile tags are checked separately post-upload)."""
    validate_tags(tags_from_report(report, "pending", "pending"), profiled=False)
    if profiled:
        for t in PROFILE_TAGS:
            pass  # profile_uri/sha256 come from the upload; only checked in validate_tags at log time


def log_run(
    report: dict[str, Any],
    profile_uri: str = "",
    profile_sha256: str = "",
    profiled: bool = True,
    small_artifacts: list[str] | None = None,
    tracking_uri: str | None = None,
) -> str:
    """Log one run to MLflow (idempotently) and return the MLflow-assigned run_id.

    Writes the run_id back into ``report`` and persists ``run_report.json`` as a (small) MLflow
    artifact so the comparison join can reference the run. For accuracy-only runs pass
    ``profiled=False`` (then ``profile_uri`` may be empty).
    """
    mlflow = _import_mlflow()
    if tracking_uri:
        mlflow.set_tracking_uri(tracking_uri)

    if not profiled:
        profile_uri = profile_uri or "none"
        profile_sha256 = profile_sha256 or "none"
    tags = tags_from_report(report, profile_uri, profile_sha256)
    validate_tags(tags, profiled=profiled)
    idem = idempotency_key(report, profile_sha256)
    tags["idempotency_key"] = idem

    mlflow.set_experiment(report["experiment_id"])
    # idempotent: if a prior attempt already logged this identity, reuse it (retry-after-crash)
    existing = mlflow.search_runs(filter_string=f"tags.idempotency_key = '{idem}'",
                                  max_results=1, output_format="list")
    if existing:
        return existing[0].info.run_id

    with mlflow.start_run(run_name=report.get("case_id")) as run:
        run_id = run.info.run_id
        report["run_id"] = run_id  # MLflow is the ID authority; write it back into the report
        mlflow.set_tags(tags)
        note = report.get("experiment_note")
        if note:
            mlflow.set_tag("mlflow.note.content", str(note)[:_TAG_VALUE_MAXLEN])
        metrics = metrics_from_report(report)
        if metrics:
            mlflow.log_metrics(metrics)
        # software fingerprint as params (what could move the numbers), captured at MEASURE time
        fp = (report.get("target") or {}).get("fingerprint", {}) or {}
        params = {f"fp_{k}": str(v)[:250] for k, v in fp.items()
                  if k not in ("accelerator", "region", "instance_type", "capacity_type", "tenant")
                  and v is not None}
        if params:
            mlflow.log_params(params)
        if report.get("thresholds"):
            mlflow.log_dict(report["thresholds"], "thresholds.json")
        noise = (report.get("perf") or {}).get("noise_floor")
        if noise:
            mlflow.log_dict(noise, "noise_floor.json")
        mlflow.log_dict(report, "run_report.json")  # the run record, now with the real run_id
        for path in small_artifacts or []:
            mlflow.log_artifact(path)
        return run_id
