"""Unit tests for the GPU/Neuron abstraction (tagged dicts)."""
from __future__ import annotations

import pytest

from . import accelerator as A


def test_validate():
    assert A.validate("gpu") == "gpu"
    assert A.validate("neuron") == "neuron"
    with pytest.raises(ValueError):
        A.validate("tpu")


def test_common_perf_is_device_neutral():
    cp = A.common_perf({"p50": 100, "p99": 400}, {"tokens_per_s": 5000, "requests_per_s": 40})
    assert set(cp) == {"latency_ms", "throughput"}
    # no device-specific keys leak in
    assert "dcgm" not in cp and "kind" not in cp


def test_gpu_and_neuron_detail_are_tagged():
    g = A.gpu_detail(dcgm={"sm_util": 0.35}, nsight={"kernel_breakdown_uri": "s3://x"})
    n = A.neuron_detail(neuron_profile={"nc_util": 0.8}, compiler={"neuronx_cc": "2.x"})
    assert A.detail_kind(g) == "gpu"
    assert A.detail_kind(n) == "neuron"


def test_detail_kind_rejects_unknown():
    with pytest.raises(ValueError):
        A.detail_kind({"kind": "bogus"})
