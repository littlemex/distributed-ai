"""Result report JSON schema + environment fingerprint.

The one piece worth investing in up front: if this shape changes later, every historical
time-series comparison of the metrics is invalidated, so freeze the schema and the environment
fingerprint first. CI gates on this report alone.

Schema v2 introduces two record kinds so that asynchronous, separate-cluster GPU/Neuron runs
fit (a single record cannot hold two sides that run in two regions at different times):

- **run record** (``kind == "run"``): one side, one accelerator, compared against the shared
  golden. Carries accuracy ``metrics`` (target vs golden), ``perf``, a ``profile_ref`` pointer
  to the S3 trace, and the experiment identity. This extends the v1 report.
- **comparison record** (``kind == "comparison"``): references two run records that share
  ``(case_id, golden_hash)`` and records the cross-accelerator verdict + deltas. Emitted by an
  offline join step; it embeds no tensors, only report URIs.

Parity is golden-anchored: each side computes its metrics against the *same* golden in-region,
so cross-accelerator parity is a comparison of two scalar run records — no cross-region tensor
shipping. Direct target-vs-target output cosine is a deferred enhancement; the schema reserves
``outputs_ref`` for it.
"""
from __future__ import annotations

import json
import os
import platform
import uuid
from typing import Any

from .hashing import sha256_file  # re-exported for callers; single hashing source

SCHEMA_VERSION = "2"

RUN = "run"
COMPARISON = "comparison"

ACCELERATORS = ("gpu", "neuron")

# Software-fingerprint env vars that can move the numerics.
_NUMERIC_ENV_KEYS = (
    "NEURON_CC_FLAGS",
    "NEURON_RT_VISIBLE_CORES",
    "XLA_USE_BF16",
    "NEURON_RT_NUM_CORES",
)


def _try(fn, default=None):
    try:
        return fn()
    except Exception:  # noqa: BLE001
        return default


def new_run_id() -> str:
    """A fresh run identifier. Kept as a helper so callers do not scatter uuid usage."""
    return uuid.uuid4().hex


def environment_fingerprint() -> dict[str, Any]:
    """Software fingerprint of the execution environment.

    Captures everything that can move the numbers via a compiler/driver/library update: torch /
    torch_neuronx / neuronx-cc / driver / transformers versions, python, platform, and the
    numeric env vars. Hardware identity is added separately by :func:`hardware_fingerprint`,
    because it is per-side and only the ``target`` side needs it.
    """
    fp: dict[str, Any] = {
        "python": platform.python_version(),
        "platform": platform.platform(),
    }
    fp["torch"] = _try(lambda: __import__("torch").__version__)
    fp["torch_neuronx"] = _try(lambda: __import__("torch_neuronx").__version__)
    fp["transformers"] = _try(lambda: __import__("transformers").__version__)

    def _pkg_version(name):
        import importlib.metadata as md

        return _try(lambda: md.version(name))

    fp["neuronx_cc"] = _pkg_version("neuronx-cc")
    fp["neuronx_runtime"] = _pkg_version("aws-neuronx-runtime-discovery")
    fp["env"] = {k: os.environ.get(k) for k in _NUMERIC_ENV_KEYS if os.environ.get(k) is not None}
    return fp


def hardware_fingerprint(
    accelerator: str,
    instance_type: str,
    region: str,
    capacity_type: str | None = None,
    tenant: str | None = None,
) -> dict[str, Any]:
    """Hardware identity for a side. Required on the ``target`` side for cost + comparison.

    ``accelerator`` must be one of :data:`ACCELERATORS`; ``capacity_type`` distinguishes
    on-demand vs reserved (Capacity Block) pricing; ``tenant`` mirrors the cluster's
    tenant-pool label so a report can be lined up with its Prometheus series.
    """
    if accelerator not in ACCELERATORS:
        raise ValueError(f"accelerator must be one of {ACCELERATORS}, got {accelerator!r}")
    fields = {
        "accelerator": accelerator,
        "instance_type": instance_type,
        "region": region,
        "capacity_type": capacity_type,
        "tenant": tenant,
    }
    return {k: v for k, v in fields.items() if v is not None}


def make_side(
    impl: str,
    dtype: str,
    version: str | None = None,
    software_fingerprint: dict[str, Any] | None = None,
    hardware: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build one side (reference = golden, or target = accelerator under test).

    ``hardware`` (from :func:`hardware_fingerprint`) is merged into the fingerprint so a single
    ``fingerprint`` map carries both software and hardware identity.
    """
    fingerprint = dict(software_fingerprint or {})
    if hardware:
        fingerprint.update(hardware)
    return {"impl": impl, "dtype": dtype, "version": version, "fingerprint": fingerprint}


def artifact_ref(uri: str, sha256: str, kind: str | None = None) -> dict[str, Any]:
    """A pointer to an S3 object (trace or outputs). ``sha256`` proves the object is the one the
    producer finalized (see the finalization contract in ``contracts/profile-artifact.md``)."""
    ref = {"uri": uri, "sha256": sha256}
    if kind is not None:
        ref["kind"] = kind
    return ref


def make_window(node: str, start_epoch: float, end_epoch: float) -> dict[str, Any]:
    """The run's execution window as a machine key for Prometheus range queries.

    Epoch seconds are used (timezone-agnostic) so the GPU (one region) and Neuron (another)
    windows correlate without timezone ambiguity; human-facing timestamps stay JST elsewhere.
    """
    return {"node": node, "start_epoch": start_epoch, "end_epoch": end_epoch}


def build_run_report(
    *,
    run_id: str | None,
    experiment_id: str,
    case_id: str,
    stage: str,
    verdict: str,
    metrics: dict[str, Any],
    thresholds: dict[str, Any],
    reference: dict[str, Any],
    target: dict[str, Any],
    golden_hash: str | None = None,
    perf: dict[str, Any] | None = None,
    perf_verdict: str | None = None,
    profile_ref: dict[str, Any] | None = None,
    outputs_ref: dict[str, Any] | None = None,
    window: dict[str, Any] | None = None,
    experiment_alias: str | None = None,
    experiment_note: str | None = None,
    timestamp_jst: str | None = None,
) -> dict[str, Any]:
    """A single-side run record (``kind == "run"``).

    ``verdict`` is the accuracy verdict (target vs golden, from :func:`verdict.judge`).
    ``perf_verdict`` stays ``None`` until ``perf`` is present. Callers pass ``timestamp_jst`` so
    this stays environment-independent (no wall-clock read here).
    """
    return {
        "kind": RUN,
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "experiment_id": experiment_id,
        "experiment_alias": experiment_alias,
        "experiment_note": experiment_note,
        "case_id": case_id,
        "stage": stage,
        "verdict": verdict,
        "metrics": metrics,
        "perf": perf,
        "perf_verdict": perf_verdict,
        "reference": reference,
        "target": target,
        "golden_hash": golden_hash,
        "profile_ref": profile_ref,
        "outputs_ref": outputs_ref,
        "thresholds": thresholds,
        "window": window,
        "timestamp_jst": timestamp_jst,
    }


def build_comparison_report(
    *,
    experiment_id: str,
    case_id: str,
    golden_hash: str | None,
    reference_run_id: str,
    target_run_id: str,
    reference_run: str,
    target_run: str,
    accuracy_parity_verdict: str,
    perf_verdict: str,
    deltas: dict[str, Any],
    timestamp_jst: str | None = None,
) -> dict[str, Any]:
    """A cross-accelerator comparison record (``kind == "comparison"``).

    References two run records by their reports-store URI + run_id (no tensors embedded). The
    join step must only emit this once it has asserted both sides share ``golden_hash``.
    """
    return {
        "kind": COMPARISON,
        "schema_version": SCHEMA_VERSION,
        "experiment_id": experiment_id,
        "case_id": case_id,
        "golden_hash": golden_hash,
        "reference_run_id": reference_run_id,
        "target_run_id": target_run_id,
        "reference_run": reference_run,
        "target_run": target_run,
        "accuracy_parity_verdict": accuracy_parity_verdict,
        "perf_verdict": perf_verdict,
        "deltas": deltas,
        "timestamp_jst": timestamp_jst,
    }


def build_report(
    case_id: str,
    stage: str,
    verdict: str,
    metrics: dict[str, Any],
    thresholds: dict[str, Any],
    reference: dict[str, Any],
    target: dict[str, Any],
    golden_hash: str | None = None,
    perf: dict[str, Any] | None = None,
    timestamp_jst: str | None = None,
    *,
    experiment_id: str | None = None,
    run_id: str | None = None,
) -> dict[str, Any]:
    """Backward-compatible shim for the v1 positional signature.

    Delegates to :func:`build_run_report`, generating a ``run_id`` and defaulting
    ``experiment_id`` to the ``case_id`` when the caller has not adopted experiments yet.
    """
    return build_run_report(
        run_id=run_id or new_run_id(),
        experiment_id=experiment_id or case_id,
        case_id=case_id,
        stage=stage,
        verdict=verdict,
        metrics=metrics,
        thresholds=thresholds,
        reference=reference,
        target=target,
        golden_hash=golden_hash,
        perf=perf,
        timestamp_jst=timestamp_jst,
    )


def comparison_from_runs(
    reference_run: dict[str, Any],
    target_run: dict[str, Any],
    *,
    reference_uri: str,
    target_uri: str,
    accuracy_parity_verdict: str,
    perf_verdict: str,
    deltas: dict[str, Any],
    timestamp_jst: str | None = None,
) -> dict[str, Any]:
    """Build a comparison record from two run records, ENFORCING the parity precondition.

    Parity is only meaningful when both sides were measured against the same golden and case, so
    this refuses (raises) unless ``golden_hash`` and ``case_id`` match — the assertion that was
    previously only a docstring comment.
    """
    rg, tg = reference_run.get("golden_hash"), target_run.get("golden_hash")
    if not rg or rg != tg:
        raise ValueError(f"golden_hash mismatch — refusing to compare: {rg!r} vs {tg!r}")
    if reference_run.get("case_id") != target_run.get("case_id"):
        raise ValueError("case_id mismatch — refusing to compare runs from different cases")
    return build_comparison_report(
        experiment_id=reference_run.get("experiment_id"),
        case_id=reference_run.get("case_id"),
        golden_hash=rg,
        reference_run_id=reference_run.get("run_id"),
        target_run_id=target_run.get("run_id"),
        reference_run=reference_uri,
        target_run=target_uri,
        accuracy_parity_verdict=accuracy_parity_verdict,
        perf_verdict=perf_verdict,
        deltas=deltas,
        timestamp_jst=timestamp_jst,
    )


def write_report(report: dict[str, Any], path: str) -> None:
    """Atomically write a report JSON (tmp + rename), UTF-8, rejecting NaN/Inf (non-standard JSON
    that strict parsers choke on). A crash mid-write leaves the old file, not a truncated one."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".writing"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, allow_nan=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
