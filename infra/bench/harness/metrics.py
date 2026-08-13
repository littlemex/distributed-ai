"""Device-independent comparison metrics. A pure numeric library that knows nothing about K8s
or Neuron.

Cosine alone is not enough (it misses scale error and a few large per-element outliers). Use
element-level metrics at the layer level and token-agreement etc. end-to-end. Functions take
torch tensors and return dicts.
"""
from __future__ import annotations

from typing import Any

import torch


def _f64(t: torch.Tensor) -> torch.Tensor:
    return t.detach().to(torch.float64).flatten()


def cosine(a: torch.Tensor, b: torch.Tensor) -> float:
    a64, b64 = _f64(a), _f64(b)
    return float(torch.dot(a64, b64) / (a64.norm() * b64.norm() + 1e-30))


def elementwise_metrics(ref: torch.Tensor, tgt: torch.Tensor) -> dict[str, Any]:
    """Element-level metrics at the layer level. ref = reference (golden), tgt = candidate."""
    assert ref.shape == tgt.shape, f"shape mismatch: {tuple(ref.shape)} vs {tuple(tgt.shape)}"
    r = ref.detach().to(torch.float64)
    t = tgt.detach().to(torch.float64)
    diff = (r - t).abs()
    denom = r.abs().clamp_min(1e-9)
    rel = diff / denom
    return {
        "shape": list(ref.shape),
        "cosine": cosine(ref, tgt),
        "max_abs_error": float(diff.max()),
        "mean_abs_error": float(diff.mean()),
        "rel_error_p99": float(torch.quantile(rel.flatten(), 0.99)),
        "rel_error_max": float(rel.max()),
        "ref_abs_mean": float(r.abs().mean()),
        "tgt_abs_mean": float(t.abs().mean()),
    }


def per_step_diff(ref: torch.Tensor, tgt: torch.Tensor, seq_dim: int = 1) -> dict[str, Any]:
    """Per-step max abs diff along the sequence (time) axis.

    This is the metric that caught the compiler bug where only t=0 matched and t>=1 diverged.
    Returns representative head/tail steps and the first step that exceeds the threshold.
    """
    r = ref.detach().to(torch.float64)
    t = tgt.detach().to(torch.float64)
    L = r.shape[seq_dim]
    per = []
    for i in range(L):
        idx = [slice(None)] * r.ndim
        idx[seq_dim] = i
        per.append(float((r[tuple(idx)] - t[tuple(idx)]).abs().max()))
    first_bad = next((i for i, d in enumerate(per) if d > 1e-2), None)
    reps = {str(i): per[i] for i in sorted(set([0, 1, 2, L // 2, L - 1])) if 0 <= i < L}
    return {"seq_len": L, "first_step_over_1e-2": first_bad, "representative": reps}


def moe_expert_agreement(ref_topk_ids: torch.Tensor, tgt_topk_ids: torch.Tensor) -> dict[str, Any]:
    """MoE expert-selection agreement. A top-k flip is invisible to element comparison, so this
    is a separate metric.

    ref/tgt_topk_ids: [..., k] selected expert ids. Measures set agreement (order-independent).
    """
    r = ref_topk_ids.detach().reshape(-1, ref_topk_ids.shape[-1])
    t = tgt_topk_ids.detach().reshape(-1, tgt_topk_ids.shape[-1])
    inter = 0
    for i in range(r.shape[0]):
        inter += len(set(r[i].tolist()) & set(t[i].tolist()))
    total = r.shape[0] * r.shape[-1]
    return {"expert_set_agreement": inter / max(total, 1), "rows": int(r.shape[0])}


def token_agreement(ref_ids: list[int], tgt_ids: list[int]) -> dict[str, Any]:
    """End-to-end greedy token-agreement rate."""
    n = min(len(ref_ids), len(tgt_ids))
    match = sum(1 for i in range(n) if ref_ids[i] == tgt_ids[i])
    first_div = next((i for i in range(n) if ref_ids[i] != tgt_ids[i]), None)
    return {"token_match_rate": match / max(n, 1), "compared": n, "first_divergence": first_div}
