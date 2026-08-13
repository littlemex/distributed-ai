"""Reference ETL adapter: an Nsight-profiled GPU run → the common experiment record.

Shows how a measurement is absorbed into the shared framework. The tool-specific part is small
and honest:
  - the trace artifact is the ``.nsys-rep`` / ``.ncu-rep`` file (opaque; uploaded for deep-dive),
  - perf metrics come from the run's *measured* latency samples + token counts (via ``perf.py``),
    not from re-parsing Nsight internals,
  - accuracy metrics come from the harness (``metrics.py``), compared against the shared golden.

A different tool (neuron-profile, or any OSS profiler) gets its own adapter with the same
signature; nothing downstream changes.
"""
from __future__ import annotations

from typing import Any

from harness import accelerator, perf, report

TRACE_KIND = "nsight"

# The golden reference identity. Its dtype matters (the accuracy noise floor is derived from an
# fp32-vs-fp64 reference), so it is a named constant, not a magic literal buried in a call.
GOLDEN_IMPL = "golden"
GOLDEN_DTYPE = "fp32"


def build_gpu_run_report(
    *,
    experiment_id: str,
    case_id: str,
    stage: str,
    golden_hash: str,
    instance_type: str,
    region: str,
    impl: str,
    dtype: str,
    accuracy_metrics: dict[str, Any],
    accuracy_verdict: str,
    latency_samples_ms: list[float],
    total_tokens: int,
    elapsed_s: float,
    num_requests: int,
    software_fingerprint: dict[str, Any],
    window: dict[str, Any] | None = None,
    timestamp_jst: str | None = None,
    perf_verdict: str | None = None,
    capacity_type: str | None = None,
    tenant: str | None = None,
    experiment_alias: str | None = None,
    experiment_note: str | None = None,
    thresholds: dict[str, Any] | None = None,
    noise_floor: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Assemble a GPU-side run-report dict from measured values (ready for :func:`base.publish_run`).

    ``software_fingerprint`` is passed in (captured on the MEASUREMENT node at measure time), not
    read here — an ETL adapter may run on a different host, so reading torch/neuronx-cc versions
    here would fingerprint the wrong environment. ``run_id`` is left ``None``: MLflow assigns it at
    log time and writes it back.
    """
    accelerator.validate("gpu")
    perf_block = perf.build_perf(latency_samples_ms, total_tokens, elapsed_s, num_requests, noise=noise_floor)
    target = report.make_side(
        impl, dtype,
        software_fingerprint=software_fingerprint,
        hardware=report.hardware_fingerprint("gpu", instance_type, region,
                                             capacity_type=capacity_type, tenant=tenant),
    )
    return report.build_run_report(
        run_id=None,
        experiment_id=experiment_id,
        case_id=case_id,
        stage=stage,
        verdict=accuracy_verdict,
        metrics=accuracy_metrics,
        thresholds=thresholds or {},
        reference=report.make_side(GOLDEN_IMPL, GOLDEN_DTYPE),
        target=target,
        golden_hash=golden_hash,
        perf=perf_block,
        perf_verdict=perf_verdict,
        window=window,
        timestamp_jst=timestamp_jst,
        experiment_alias=experiment_alias,
        experiment_note=experiment_note,
    )
