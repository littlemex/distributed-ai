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


class TestPairedStatistic:
    """The number admission rests on. Every case here is a way it could say yes when it should not."""

    def stat(self, box, base, **kw):
        from benchctl import scorers
        return scorers.paired_non_inferiority(box, base, margin_pp=kw.pop("margin_pp", 2.0), **kw)

    def test_identical_layers_are_non_inferior(self):
        r = self.stat([True] * 40 + [False] * 10, [True] * 40 + [False] * 10)
        assert r.difference_pp == 0.0 and r.non_inferior
        assert r.only_box == 0 and r.only_baseline == 0

    def test_a_clearly_worse_layer_is_refused(self):
        box = [True] * 20 + [False] * 30
        base = [True] * 45 + [False] * 5
        r = self.stat(box, base)
        assert r.difference_pp < -40 and not r.non_inferior

    def test_only_the_discordant_pairs_move_the_difference(self):
        """Items both layers get right or both get wrong carry no information about the difference,
        which is why the paired design needs so many fewer items than an absolute bound."""
        box = [True] * 30 + [False, True] + [False] * 18
        base = [True] * 30 + [True, False] + [False] * 18
        r = self.stat(box, base)
        assert (r.only_baseline, r.only_box) == (1, 1)
        assert r.difference_pp == 0.0

    def test_the_bound_is_one_sided_and_below_the_estimate(self):
        box = [True] * 38 + [False] * 10
        base = [True] * 36 + [False] * 12
        r = self.stat(box, base, confidence=0.80)
        assert r.lcb_pp <= r.difference_pp

    def test_a_higher_confidence_gives_a_lower_bound(self):
        box = [True] * 38 + [False] * 10
        base = [True] * 36 + [False] * 12
        assert self.stat(box, base, confidence=0.95).lcb_pp <= self.stat(box, base, confidence=0.80).lcb_pp

    def test_mismatched_lengths_are_refused(self):
        import pytest as _pytest
        with _pytest.raises(ValueError, match="same items"):
            self.stat([True, False], [True])

    def test_an_absolute_bound_at_this_n_would_have_refused_it(self):
        """Why the design is paired: the same data, described absolutely, does not clear a 0.85 floor."""
        from benchctl import scorers
        assert scorers.wilson_lower(38, 48, 0.80) < 0.85
        assert self.stat([True] * 38 + [False] * 10, [True] * 36 + [False] * 12).non_inferior


class TestTheRateCardIsTheAuthority:
    """A price typed into a spec is unreviewable, and one of them was wrong by 17x.

    `gemma-4` was carried at $0.30 input where the gateway's own card says $5.00, so its measured cost was
    understated seventeenfold and it was published as the cheapest layer on two frontiers. Nothing about a
    wrong price looks wrong, so the only thing that can catch it is a comparison against the card.
    """

    CARD = {
        "rates": {
            "claude-haiku-4-5": {"input_usd_per_mtok": 1.0, "output_usd_per_mtok": 5.0,
                                 "cache_read_usd_per_mtok": 0.1, "status": "vendor_list",
                                 "source": "vendor list price"},
            # AWS's published rate, not the gateway card's over-charge default of $5.00.
            "gemma-4": {"input_usd_per_mtok": 0.14, "output_usd_per_mtok": 0.40,
                        "status": "aws_price_list", "source": "AWS Price List API, us-east-2, standard"},
        },
        "unpriced": {"gpt-5.5": "the gateway maps it to a key that repeats its over-charge default"},
    }

    def layer(self, **over) -> spec.Layer:
        base = {"id": "api-gemma-4", "kind": "api", "model": "gemma-4",
                "endpoint": "https://example.invalid/v1/chat/completions"}
        return spec.Layer(**(base | over))

    def test_a_layer_with_no_rates_gets_them_from_the_table(self):
        out = spec.apply_rate_card({"api-gemma-4": self.layer()}, self.CARD)
        got = out["api-gemma-4"]
        assert (got.input_usd_per_mtok, got.output_usd_per_mtok) == (0.14, 0.40)
        assert got.pricing_status == "aws_price_list"

    def test_a_literal_that_disagrees_with_the_table_is_refused(self):
        with pytest.raises(ValueError) as excinfo:
            spec.apply_rate_card({"api-gemma-4": self.layer(input_usd_per_mtok=0.30)}, self.CARD)
        assert "0.3" in str(excinfo.value) and "0.14" in str(excinfo.value)

    def test_a_literal_that_agrees_is_allowed(self):
        out = spec.apply_rate_card(
            {"api-haiku-4-5": self.layer(id="api-haiku-4-5", model="claude-haiku-4-5",
                                         input_usd_per_mtok=1.0, output_usd_per_mtok=5.0)}, self.CARD)
        assert out["api-haiku-4-5"].pricing_status == "vendor_list"

    def test_a_model_listed_as_unpriced_is_a_placeholder_rather_than_a_failure(self):
        """The point of `unpriced`: comparable on quality and latency, never on cost."""
        out = spec.apply_rate_card({"api-gpt-55": self.layer(id="api-gpt-55", model="gpt-5.5")}, self.CARD)
        got = out["api-gpt-55"]
        assert got.pricing_status == "placeholder"
        assert got.input_usd_per_mtok is None

    def test_a_self_hosted_layer_is_left_alone(self):
        box = spec.Layer(id="box", kind="self_hosted", model="Qwen/Qwen3.6-35B-A3B",
                         endpoint="http://box.invalid/v1/chat/completions", hourly_usd=15.2174,
                         input_usd_per_mtok=0.236, output_usd_per_mtok=4.12, serving_ref="sha256:x")
        out = spec.apply_rate_card({"box": box}, self.CARD)
        assert out["box"] is box

    def test_an_api_layer_the_table_does_not_know_is_refused_rather_than_guessed(self):
        with pytest.raises(ValueError) as excinfo:
            spec.apply_rate_card({"api-x": self.layer(id="api-x", model="not-in-the-table")}, self.CARD)
        assert "neither priced nor listed as unpriced" in str(excinfo.value)

    def test_every_api_layer_the_specs_use_is_either_sourced_or_declared_unpriced(self):
        """No third state. A layer with no price and no `unpriced` entry would be silently uncomparable."""
        card = spec._rate_card()
        assert card, "specs/model-rates.json is missing; run scripts/import_model_rates.py"
        for path in sorted((ROOT / "specs/runs").glob("*.yaml")):
            run = spec.load_run(path)
            for cell in run.cells:
                layer = cell.layer
                if layer.kind != "api":
                    continue
                priced = layer.input_usd_per_mtok is not None
                declared_unpriced = layer.pricing_status == "placeholder"
                assert priced or declared_unpriced, f"{path.name}: {layer.id}"

    def test_the_sourced_table_carries_a_source_for_every_price(self):
        """A number with no source is not a price, which is the whole lesson of this file."""
        for alias, row in (spec._rate_card().get("rates") or {}).items():
            assert row.get("source"), alias
            assert row.get("status") in {"aws_price_list", "vendor_list", "gateway_card"}, alias
