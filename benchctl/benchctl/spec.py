"""The five declarations, and the refusals that keep a run honest.

Loading YAML is the boring half. The half worth writing down is what this module refuses:

* a cell with no `ephemeral_storage` — a benchmark Job once filled a node's disk pulling a container
  image and was evicted, taking the run with it, so the request is mandatory rather than defaulted;
* a run whose `serving_ref` names a manifest that does not exist — a set of measurements was once
  attributed to a configuration it was not taken on;
* a quality cell asking for the operating concurrency, or a perf cell asking for one request in
  flight. The two cells measure different quantities and swapping their concurrency silently produces
  numbers that look fine: `p_i` wants determinism, `S_box_i` is a property of the batch.

Nothing here talks to Kubernetes or to a model. That is deliberate: these are the decisions that
produce a plausible wrong number if they are wrong, and they should be testable without a cluster.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

import yaml

# A quality cell is deterministic and shallow; a perf cell runs at the operating point. Enforced
# rather than documented, because the failure is silent.
QUALITY_MAX_CONCURRENCY = 4
PERF_MIN_CONCURRENCY = 8
CELL_KINDS = ("quality", "perf")
IDENT = re.compile(r"^[a-z0-9][a-z0-9._-]{1,62}$")


class SpecError(ValueError):
    """A declaration that cannot be run as written. The message says which file and which field."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise SpecError(message)


def _ident(value: Any, where: str) -> str:
    _require(isinstance(value, str) and bool(IDENT.match(value)),
             f"{where}: expected a lowercase identifier, got {value!r}")
    return value


@dataclass(frozen=True)
class Layer:
    """Something that serves requests, with what it costs to use it.

    An API layer is priced per token by its provider; the box is priced by the hour and its per-token
    figures are derived from measured throughput, which is why `hourly_usd` and `pricing_status` are
    here. `pricing_status` exists because several models in the gateway's table share a placeholder
    rate: a layer priced by placeholder may be compared on quality and must not be compared on cost.
    """

    id: str
    kind: str                      # "api" | "self_hosted"
    model: str
    endpoint: str
    input_usd_per_mtok: float | None = None
    output_usd_per_mtok: float | None = None
    cache_read_usd_per_mtok: float | None = None
    hourly_usd: float | None = None
    serving_ref: str | None = None
    pricing_status: str = "measured"   # "measured" | "list" | "placeholder"

    @staticmethod
    def load(raw: dict, where: str) -> "Layer":
        kind = raw.get("kind")
        _require(kind in ("api", "self_hosted"), f"{where}: kind must be api or self_hosted")
        layer = Layer(
            id=_ident(raw.get("id"), f"{where}.id"),
            kind=kind,
            model=str(raw.get("model") or ""),
            endpoint=str(raw.get("endpoint") or ""),
            input_usd_per_mtok=raw.get("input_usd_per_mtok"),
            output_usd_per_mtok=raw.get("output_usd_per_mtok"),
            cache_read_usd_per_mtok=raw.get("cache_read_usd_per_mtok"),
            hourly_usd=raw.get("hourly_usd"),
            serving_ref=raw.get("serving_ref"),
            pricing_status=raw.get("pricing_status", "measured"),
        )
        _require(bool(layer.model) and bool(layer.endpoint), f"{where}: model and endpoint are required")
        _require(layer.pricing_status in ("measured", "list", "placeholder"),
                 f"{where}: pricing_status must be measured, list or placeholder")
        if layer.kind == "self_hosted":
            # The box bills wall clock. Without the hourly rate nothing about its cost can be said,
            # and without the serving manifest the numbers cannot be attributed to a configuration.
            _require(layer.hourly_usd is not None, f"{where}: a self_hosted layer needs hourly_usd")
            _require(bool(layer.serving_ref), f"{where}: a self_hosted layer needs serving_ref")
        else:
            _require(layer.input_usd_per_mtok is not None and layer.output_usd_per_mtok is not None,
                     f"{where}: an api layer needs input_usd_per_mtok and output_usd_per_mtok")
        return layer

    @property
    def comparable_on_cost(self) -> bool:
        """Whether this layer may appear in a cost comparison at all."""
        return self.pricing_status != "placeholder"


@dataclass(frozen=True)
class Suite:
    """One family's items, its quality floor, and the layer that floor is measured against.

    `baseline_layer` is not decoration. The objective's numerator is what the family *would* have paid,
    so non-inferiority has to be shown against the cheapest layer that meets the floor — proving it
    against a dearer one and then claiming that layer's price is how a saving gets overstated.
    """

    id: str
    family: str
    items: str                     # a path or dataset reference; resolved by the task plugin
    task_plugin: str
    scorer: str
    baseline_layer: str
    floor: dict = field(default_factory=dict)
    length_bins: tuple[int, ...] = ()

    @staticmethod
    def load(raw: dict, where: str) -> "Suite":
        suite = Suite(
            id=_ident(raw.get("id"), f"{where}.id"),
            family=str(raw.get("family") or ""),
            items=str(raw.get("items") or ""),
            task_plugin=str(raw.get("task_plugin") or ""),
            scorer=str(raw.get("scorer") or ""),
            baseline_layer=_ident(raw.get("baseline_layer"), f"{where}.baseline_layer"),
            floor=raw.get("floor") or {},
            length_bins=tuple(raw.get("length_bins") or ()),
        )
        for name in ("family", "items", "task_plugin", "scorer"):
            _require(bool(getattr(suite, name)), f"{where}: {name} is required")
        _require(bool(suite.floor), f"{where}: floor is required — a suite with no floor cannot admit")
        return suite


@dataclass(frozen=True)
class OperationPoint:
    """A knob setting, and the serving configuration it was set on.

    The comparison unit for everything downstream is the operation point, not the policy: a policy
    without knobs is one point and a policy with knobs is a set of them, and they belong in the same
    table.
    """

    id: str
    cell_kind: str
    concurrency: int
    input_tokens: int
    output_tokens: int
    ephemeral_storage: str
    serving_ref: str | None = None
    replicas: int | None = None
    tensor_parallel: int | None = None

    @staticmethod
    def load(raw: dict, where: str) -> "OperationPoint":
        point = OperationPoint(
            id=_ident(raw.get("id"), f"{where}.id"),
            cell_kind=str(raw.get("cell_kind") or ""),
            concurrency=int(raw.get("concurrency") or 0),
            input_tokens=int(raw.get("input_tokens") or 0),
            output_tokens=int(raw.get("output_tokens") or 0),
            ephemeral_storage=str(raw.get("ephemeral_storage") or ""),
            serving_ref=raw.get("serving_ref"),
            replicas=raw.get("replicas"),
            tensor_parallel=raw.get("tensor_parallel"),
        )
        _require(point.cell_kind in CELL_KINDS, f"{where}: cell_kind must be one of {CELL_KINDS}")
        _require(point.concurrency > 0, f"{where}: concurrency must be positive")
        # A benchmark Job once evicted a node by filling its disk with a container image. The request
        # is mandatory so that the scheduler can refuse instead of the kubelet.
        _require(bool(point.ephemeral_storage),
                 f"{where}: ephemeral_storage is required — an image that does not fit evicts the node")
        if point.cell_kind == "quality":
            _require(point.concurrency <= QUALITY_MAX_CONCURRENCY,
                     f"{where}: a quality cell measures p_i and must be deterministic; "
                     f"concurrency {point.concurrency} exceeds {QUALITY_MAX_CONCURRENCY}")
        else:
            _require(point.concurrency >= PERF_MIN_CONCURRENCY,
                     f"{where}: a perf cell measures S_box at the operating point; "
                     f"concurrency {point.concurrency} is below {PERF_MIN_CONCURRENCY}")
        return point


@dataclass(frozen=True)
class Policy:
    """Which layer takes the work, and what makes it escalate."""

    id: str
    steps: tuple[dict, ...]

    @staticmethod
    def load(raw: dict, where: str) -> "Policy":
        steps = tuple(raw.get("steps") or ())
        _require(bool(steps), f"{where}: a policy needs at least one step")
        for i, step in enumerate(steps):
            _require("layer_ref" in step, f"{where}.steps[{i}]: layer_ref is required")
        return Policy(id=_ident(raw.get("id"), f"{where}.id"), steps=steps)


@dataclass(frozen=True)
class Cell:
    """One unit of work: a suite on a layer under a policy at an operation point."""

    id: str
    kind: str
    suite: Suite
    layer: Layer
    policy: Policy
    point: OperationPoint
    seed: int


@dataclass(frozen=True)
class Run:
    """An immutable, expanded plan. What `submit` writes to the artifact root as `manifest.json`."""

    id: str
    cells: tuple[Cell, ...]
    serving_ref: str | None

    def manifest(self) -> dict:
        return {
            "run_id": self.id,
            "serving_ref": self.serving_ref,
            "cells": [
                {
                    "cell_id": c.id,
                    "kind": c.kind,
                    "suite": c.suite.id,
                    "family": c.suite.family,
                    "layer": c.layer.id,
                    "policy": c.policy.id,
                    "operation_point": c.point.id,
                    "concurrency": c.point.concurrency,
                    "seed": c.seed,
                }
                for c in self.cells
            ],
        }


def _index(raws: Iterable[dict], loader, kind: str) -> dict:
    out: dict = {}
    for i, raw in enumerate(raws):
        obj = loader(raw, f"{kind}[{i}]")
        _require(obj.id not in out, f"{kind}: duplicate id {obj.id!r}")
        out[obj.id] = obj
    return out


def load_run(path: Path) -> Run:
    """Read a run spec and everything it references, and expand it into cells.

    A run spec is self-contained on purpose: it inlines or includes its layers, suites, policies and
    operation points, so the manifest written beside the results is enough to say what was run without
    resolving anything against a moving git tree.
    """
    raw = yaml.safe_load(path.read_text()) or {}
    run_id = _ident(raw.get("id"), f"{path}.id")
    layers = _index(raw.get("layers") or (), Layer.load, "layers")
    suites = _index(raw.get("suites") or (), Suite.load, "suites")
    policies = _index(raw.get("policies") or (), Policy.load, "policies")
    points = _index(raw.get("operation_points") or (), OperationPoint.load, "operation_points")
    _require(bool(raw.get("cells")), f"{path}: a run needs cells")

    cells = []
    for i, spec in enumerate(raw["cells"]):
        where = f"cells[{i}]"
        for key in ("suite", "layer", "policy", "operation_point"):
            _require(key in spec, f"{where}: {key} is required")
        _require(spec["suite"] in suites, f"{where}: no suite {spec['suite']!r} in this run")
        _require(spec["layer"] in layers, f"{where}: no layer {spec['layer']!r} in this run")
        _require(spec["policy"] in policies, f"{where}: no policy {spec['policy']!r} in this run")
        _require(spec["operation_point"] in points,
                 f"{where}: no operation_point {spec['operation_point']!r} in this run")
        point = points[spec["operation_point"]]
        suite = suites[spec["suite"]]
        layer = layers[spec["layer"]]
        # The baseline a floor is measured against has to be in the run, or the comparison is a claim
        # about a number nobody took.
        _require(suite.baseline_layer in layers,
                 f"{where}: suite {suite.id!r} compares against layer {suite.baseline_layer!r}, "
                 "which this run does not include")
        for step in policies[spec["policy"]].steps:
            _require(step["layer_ref"] in layers,
                     f"{where}: policy step references layer {step['layer_ref']!r}, not in this run")
        cell_id = spec.get("id") or f"{suite.id}--{layer.id}--{point.id}"
        cells.append(
            Cell(
                id=_ident(cell_id, f"{where}.id"),
                kind=point.cell_kind,
                suite=suite,
                layer=layer,
                policy=policies[spec["policy"]],
                point=point,
                seed=int(spec.get("seed", 0)),
            )
        )

    seen: set[str] = set()
    for cell in cells:
        _require(cell.id not in seen, f"{path}: duplicate cell id {cell.id!r}")
        seen.add(cell.id)

    run = Run(id=run_id, cells=tuple(cells), serving_ref=raw.get("serving_ref"))
    # Every self-hosted layer must agree with the run about which serving configuration was used.
    for cell in run.cells:
        if cell.layer.kind == "self_hosted" and run.serving_ref:
            _require(cell.layer.serving_ref == run.serving_ref,
                     f"cell {cell.id}: layer {cell.layer.id} was measured on "
                     f"{cell.layer.serving_ref}, but the run declares {run.serving_ref}")
    return run


def check_serving_manifest(run: Run, manifest_root: Path) -> dict:
    """The manifest the run claims must exist, and it must carry the engine's flags.

    `enable_prefix_caching` on its own decides whether a whole family belongs on the box, so a manifest
    that only summarises the configuration is not evidence about the configuration.
    """
    _require(bool(run.serving_ref), "this run declares no serving_ref, so nothing can be verified")
    path = manifest_root / f"{run.serving_ref.replace(':', '_')}.json"
    _require(path.exists(), f"no serving manifest at {path} for {run.serving_ref}")
    manifest = json.loads(path.read_text())
    for key in ("model", "engine", "engine_version", "topology", "engine_flags", "hourly_usd"):
        _require(key in manifest, f"{path}: a serving manifest needs {key}")
    _require("enable_prefix_caching" in manifest["engine_flags"],
             f"{path}: engine_flags must record enable_prefix_caching as the engine reported it")
    return manifest
