"""GPU/Neuron abstraction for perf records — tagged dicts, not a class hierarchy.

Mirrors ``metrics.py``'s "knows no chip" stance: the *verdict* only ever sees device-neutral
``CommonPerf`` (latency + throughput). Device-specific detail (DCGM/Nsight for GPU,
neuron-profile for Neuron) is *diagnosis only* — reached via a report's ``profile_ref`` when a
case fails — and is never an input to a pass/fail decision.

We deliberately avoid a class hierarchy / registry until a third accelerator arrives
(``infra/bench`` README: "abstract only once a third backend arrives"). ``accelerator`` is a
dispatch key, so the normalized detail *shapes* are defined inductively from the first real GPU
and Neuron traces rather than guessed up front.
"""
from __future__ import annotations

from typing import Any

from .report import ACCELERATORS

GPU = "gpu"
NEURON = "neuron"


def validate(accelerator: str) -> str:
    if accelerator not in ACCELERATORS:
        raise ValueError(f"accelerator must be one of {ACCELERATORS}, got {accelerator!r}")
    return accelerator


def common_perf(latency_ms: dict[str, float], throughput: dict[str, float]) -> dict[str, Any]:
    """The device-neutral perf view — the only thing ``verdict.judge_perf`` consumes.

    Kept minimal on purpose: adding device-specific fields here would leak the abstraction into
    the verdict. Device detail belongs in :func:`gpu_detail` / :func:`neuron_detail`.
    """
    return {"latency_ms": dict(latency_ms), "throughput": dict(throughput)}


def gpu_detail(dcgm: dict[str, Any] | None = None, nsight: dict[str, Any] | None = None) -> dict[str, Any]:
    """GPU diagnosis payload (tagged ``kind == "gpu"``). ``nsight`` typically carries a
    ``kernel_breakdown_uri`` rather than inline data."""
    return {"kind": GPU, "dcgm": dcgm or {}, "nsight": nsight or {}}


def neuron_detail(
    neuron_profile: dict[str, Any] | None = None, compiler: dict[str, Any] | None = None
) -> dict[str, Any]:
    """Neuron diagnosis payload (tagged ``kind == "neuron"``). ``compiler`` records e.g. the
    ``neuronx-cc`` version that shaped the trace."""
    return {"kind": NEURON, "neuron_profile": neuron_profile or {}, "compiler": compiler or {}}


def detail_kind(detail: dict[str, Any]) -> str:
    """Read the accelerator tag off a detail dict (dispatch key), validating it."""
    return validate(detail.get("kind", ""))
