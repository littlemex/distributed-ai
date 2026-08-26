"""Tests for the refusals. Each one is a way a run could have produced a plausible wrong number.

No cluster and no model: everything here is a decision about a declaration, and decisions should be
testable without spending a GPU.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from benchctl import spec  # noqa: E402

SEED_RUN = ROOT / "specs/runs/classification-seed.yaml"


def run_dict() -> dict:
    return yaml.safe_load(SEED_RUN.read_text())


def write(tmp_path: Path, data: dict) -> Path:
    path = tmp_path / "run.yaml"
    path.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
    return path


class TestTheSeedRunIsValid:
    def test_it_loads(self):
        run = spec.load_run(SEED_RUN)
        assert run.id == "2026-08-27-classification-seed"
        assert {c.kind for c in run.cells} == {"quality", "perf"}

    def test_the_manifest_names_every_cell(self):
        run = spec.load_run(SEED_RUN)
        assert len(run.manifest()["cells"]) == len(run.cells)


class TestConcurrencyBelongsToTheCellKind:
    """The two cells measure different quantities. Swapping their concurrency is silent: a quality
    cell at c=16 still produces scores, and a perf cell at c=1 still produces a throughput number --
    both wrong, and neither obviously so."""

    def test_a_quality_cell_may_not_run_at_the_operating_point(self, tmp_path):
        data = run_dict()
        for point in data["operation_points"]:
            if point["id"] == "quality-c1":
                point["concurrency"] = 16
        with pytest.raises(spec.SpecError, match="deterministic"):
            spec.load_run(write(tmp_path, data))

    def test_a_perf_cell_may_not_run_at_one_request_in_flight(self, tmp_path):
        data = run_dict()
        for point in data["operation_points"]:
            if point["id"] == "perf-c16":
                point["concurrency"] = 1
        with pytest.raises(spec.SpecError, match="operating point"):
            spec.load_run(write(tmp_path, data))


class TestEphemeralStorageIsMandatory:
    def test_a_point_without_it_is_refused(self, tmp_path):
        """A benchmark Job filled a node's disk pulling its image and was evicted, taking the run with
        it. The scheduler can refuse where the kubelet can only kill."""
        data = run_dict()
        for point in data["operation_points"]:
            point.pop("ephemeral_storage", None)
        with pytest.raises(spec.SpecError, match="ephemeral_storage"):
            spec.load_run(write(tmp_path, data))


class TestCostComparability:
    def test_a_placeholder_price_is_not_comparable_on_cost(self):
        layer = spec.Layer.load(
            {"id": "api-gemma-4", "kind": "api", "model": "gemma-4", "endpoint": "https://x/v1",
             "input_usd_per_mtok": 5.0, "output_usd_per_mtok": 25.0, "pricing_status": "placeholder"},
            "layers[0]",
        )
        assert not layer.comparable_on_cost

    def test_a_measured_price_is(self):
        layer = spec.Layer.load(
            {"id": "box", "kind": "self_hosted", "model": "m", "endpoint": "http://x",
             "hourly_usd": 15.2174, "serving_ref": "sha256:abc"},
            "layers[0]",
        )
        assert layer.comparable_on_cost

    def test_a_self_hosted_layer_without_an_hourly_rate_is_refused(self):
        with pytest.raises(spec.SpecError, match="hourly_usd"):
            spec.Layer.load(
                {"id": "box", "kind": "self_hosted", "model": "m", "endpoint": "http://x",
                 "serving_ref": "sha256:abc"},
                "layers[0]",
            )

    def test_a_self_hosted_layer_without_a_serving_ref_is_refused(self):
        """Its numbers cannot be attributed to a configuration, which is the failure that produced a
        set of measurements taken with prefix caching believed on and the engine declining it."""
        with pytest.raises(spec.SpecError, match="serving_ref"):
            spec.Layer.load(
                {"id": "box", "kind": "self_hosted", "model": "m", "endpoint": "http://x",
                 "hourly_usd": 15.2174},
                "layers[0]",
            )


class TestTheBaselineMustBePresent:
    def test_a_suite_comparing_against_an_absent_layer_is_refused(self, tmp_path):
        """A floor measured against a layer nobody ran is a claim about a number nobody took."""
        data = run_dict()
        data["layers"] = [l for l in data["layers"] if l["id"] != "api-haiku-4-5"]
        data["cells"] = [c for c in data["cells"] if c["layer"] != "api-haiku-4-5"]
        with pytest.raises(spec.SpecError, match="does not include"):
            spec.load_run(write(tmp_path, data))

    def test_a_suite_without_a_floor_is_refused(self, tmp_path):
        data = run_dict()
        for suite in data["suites"]:
            suite.pop("floor", None)
        with pytest.raises(spec.SpecError, match="floor"):
            spec.load_run(write(tmp_path, data))


class TestServingRefAgreement:
    def test_a_layer_measured_elsewhere_is_refused(self, tmp_path):
        data = run_dict()
        for layer in data["layers"]:
            if layer["kind"] == "self_hosted":
                layer["serving_ref"] = "sha256:a-different-configuration"
        with pytest.raises(spec.SpecError, match="but the run declares"):
            spec.load_run(write(tmp_path, data))


class TestTheServingManifest:
    def manifest(self, **overrides) -> dict:
        base = {
            "model": "Qwen/Qwen3.6-35B-A3B-FP8",
            "engine": "vllm",
            "engine_version": "0.27.1",
            "topology": {"tensor_parallel": 2, "replicas": 2, "instance_type": "g6e.12xlarge"},
            "engine_flags": {"enable_prefix_caching": False, "kv_cache_dtype": "auto"},
            "hourly_usd": 15.2174,
        }
        base.update(overrides)
        return base

    def write(self, tmp_path: Path, digest: str, manifest: dict) -> Path:
        root = tmp_path / "serving"
        root.mkdir(exist_ok=True)
        (root / f"{digest.replace(':', '_')}.json").write_text(json.dumps(manifest))
        return root

    def test_a_complete_manifest_passes(self, tmp_path):
        run = spec.load_run(SEED_RUN)
        root = self.write(tmp_path, run.serving_ref, self.manifest())
        assert spec.check_serving_manifest(run, root)["engine"] == "vllm"

    def test_a_missing_manifest_is_refused(self, tmp_path):
        run = spec.load_run(SEED_RUN)
        with pytest.raises(spec.SpecError, match="no serving manifest"):
            spec.check_serving_manifest(run, tmp_path / "serving")

    def test_a_manifest_that_omits_the_prefix_caching_flag_is_refused(self, tmp_path):
        """That flag alone decides whether a whole family belongs on the box, so a manifest that
        summarises the configuration is not evidence about the configuration."""
        run = spec.load_run(SEED_RUN)
        root = self.write(tmp_path, run.serving_ref,
                          self.manifest(engine_flags={"kv_cache_dtype": "auto"}))
        with pytest.raises(spec.SpecError, match="enable_prefix_caching"):
            spec.check_serving_manifest(run, root)


class TestIdentifiers:
    def test_a_duplicate_cell_id_is_refused(self, tmp_path):
        data = run_dict()
        data["cells"][1]["id"] = data["cells"][0]["id"]
        with pytest.raises(spec.SpecError, match="duplicate cell id"):
            spec.load_run(write(tmp_path, data))

    def test_an_upper_case_id_is_refused(self, tmp_path):
        data = run_dict()
        data["id"] = "2026-08-27-Classification"
        with pytest.raises(spec.SpecError, match="lowercase identifier"):
            spec.load_run(write(tmp_path, data))
