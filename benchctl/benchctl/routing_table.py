"""The accumulating routing table: what every layer scored on every family, item by item.

The point of this file is that a routing decision needs a table, and a table has to survive models being
added to it one at a time. Today's OCR run is the argument for the shape it takes: four layers reported
0.845, 0.703, 0.906 and 0.965, and not one of those numbers was comparable to another, because each layer
answered a different subset — 0, 39, 44 and 77 items excluded, for two unrelated reasons. A table of
headline rates would have recorded a clean-looking ranking that was an artifact of which items each layer
was allowed to attempt.

So the table stores **per-item verdicts, not rates**. Everything else is derived:

* Any pair of layers can be compared on the intersection of what they both answered, at any time, without
  re-running either. Adding an eleventh model means measuring it once on the fixed item set and merging;
  its comparison against the ten already there is arithmetic.
* The one bit that decides routing policy falls out for free. If one layer's successes are a subset of
  another's, escalation is safe — it can only recover. If they cross, escalation cannot reach the union and
  the family needs a predictive router. Measured on SWE-bench it nested; measured on OCR every pair crossed.
  That is per family, so it has to be stored per family.
* Item sets cannot drift silently. Each suite carries a fingerprint of its item ids, and merging a layer
  measured against a different set is refused rather than averaged.

What is deliberately not here: a policy, a weighting of the axes, or a recommendation. The table is the
evidence a router reads. Turning three axes into one choice belongs to whoever is asking, and both advisors
were clear that users cannot state exchange rates between dollars, milliseconds and accuracy points — so
the table keeps them separate and lets a caller impose floors and ceilings instead.
"""

from __future__ import annotations

import hashlib
import json
import statistics
from math import comb
from pathlib import Path
from typing import Iterable

SCHEMA = 1


def _fingerprint(item_ids: Iterable[str]) -> str:
    h = hashlib.sha256()
    for i in sorted(item_ids):
        h.update(i.encode())
        h.update(b"\0")
    return "sha256:" + h.hexdigest()[:32]


def _mcnemar_exact(only_a: int, only_b: int) -> float:
    """Two-sided exact test on the discordant pairs, which are the only pairs carrying information."""
    m = only_a + only_b
    if m == 0:
        return 1.0
    k = min(only_a, only_b)
    return min(1.0, 2 * sum(comb(m, i) for i in range(k + 1)) / 2**m)


def _read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().split("\n") if line.strip()]


def _exclusion_reason(error: str | None, finish_reason: str | None) -> str:
    """Bucket a failure by cause, because the cause decides whether it is the model's fault.

    Today's two buckets were a gateway request-size cap and a token budget that truncated a reasoning
    model to silence. Neither is a quality signal, and a table that recorded them as "excluded: 77" would
    have lost the distinction that matters most when reading the rates.
    """
    text = error or ""
    if "content exceeds" in text or "422" in text:
        return "request_too_large"
    if "is deprecated" in text or "ValidationException" in text:
        return "parameter_rejected"
    if "unsupported_content" in text:
        return "content_type_unsupported"
    if text:
        return "transport_other"
    if finish_reason == "max_tokens":
        return "truncated_before_any_text"
    return "empty_reply"


def ingest_cell(run_dir: Path, cell_id: str, score_version: str = "v1") -> dict:
    """One cell's per-item verdicts, its exclusions by cause, and its cost and latency."""
    cell = run_dir / cell_id
    verdicts: dict[str, int | None] = {}
    excluded: dict[str, int] = {}
    for row in _read_jsonl(cell / f"score.{score_version}.jsonl"):
        verdicts[row["item_id"]] = None if row.get("excluded") else int(bool(row["passed"]))

    responses = {r["item_id"]: r for r in _read_jsonl(cell / "response.jsonl")}
    for item_id, verdict in verdicts.items():
        if verdict is None:
            r = responses.get(item_id, {})
            reason = _exclusion_reason(r.get("error"), r.get("finish_reason"))
            excluded[reason] = excluded.get(reason, 0) + 1

    latencies = sorted(r["latency_s"] for r in responses.values() if r.get("latency_s"))
    summary = json.loads((cell / "summary.json").read_text()) if (cell / "summary.json").exists() else {}
    scored = [v for v in verdicts.values() if v is not None]
    api_usd = float(summary.get("api_usd") or 0.0)
    box_usd = float(summary.get("box_usd_at_full_utilisation") or 0.0)
    total = api_usd or box_usd
    return {
        "cell_id": cell_id,
        "verdicts": verdicts,
        "excluded_by_reason": excluded,
        "summary": {"attempted": len(verdicts), "scored": len(scored), "passed": sum(scored),
                    "rate": (sum(scored) / len(scored)) if scored else None},
        "cost": {
            "usd_total": total,
            "usd_per_scored_item": (total / len(scored)) if scored else None,
            # Which ledger the number came from, because they are not the same kind of number: one is a
            # bill and the other is an hourly rate divided by throughput at an assumed occupancy.
            "basis": "api_billed" if api_usd else ("box_hour_at_full_occupancy" if box_usd else "unknown"),
        },
        "latency_s": {
            "p50": statistics.median(latencies) if latencies else None,
            "p95": latencies[min(len(latencies) - 1, int(0.95 * (len(latencies) - 1)))] if latencies else None,
            "wall_total": summary.get("wall_s"),
        },
    }


def layer_caveats(layer) -> list[str]:
    """Reasons a rate from this layer is not the same kind of measurement as another's."""
    out = []
    if not getattr(layer, "sends_temperature", True):
        out.append("temperature_not_pinned: the model rejects the parameter, so its answers are a "
                   "distribution rather than a point and its interval is wider than the arithmetic")
    if getattr(layer, "image_style", "openai") != "openai":
        out.append("image_wire_format=anthropic: images travel a different endpoint than text")
    if getattr(layer, "pricing_status", "measured") == "placeholder":
        out.append("pricing_placeholder: comparable on quality, not on cost")
    if getattr(layer, "kind", "") == "self_hosted":
        out.append("cost_basis=box_hour_at_full_occupancy: a rate, not a bill, and only true when full")
    return out


def pairs_for(layers: dict) -> dict:
    """Every pairwise comparison on the intersection of what both layers answered.

    Recomputed on every merge rather than stored incrementally, so adding a layer cannot leave a stale
    comparison behind.
    """
    out = {}
    names = sorted(layers)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            va, vb = layers[a]["verdicts"], layers[b]["verdicts"]
            shared = [k for k in va if va[k] is not None and vb.get(k) is not None]
            if not shared:
                out[f"{a}|{b}"] = {"n": 0, "note": "no items answered by both"}
                continue
            only_a = sum(1 for k in shared if va[k] and not vb[k])
            only_b = sum(1 for k in shared if vb[k] and not va[k])
            pa = sum(va[k] for k in shared) / len(shared)
            pb = sum(vb[k] for k in shared) / len(shared)
            if only_a and only_b:
                structure = "crossing"
            elif only_a:
                structure = f"nested:{b}_wins_subset_of_{a}"
            elif only_b:
                structure = f"nested:{a}_wins_subset_of_{b}"
            else:
                structure = "identical"
            out[f"{a}|{b}"] = {
                "n": len(shared),
                f"rate_{a}": round(pa, 4), f"rate_{b}": round(pb, 4),
                "difference_pp": round((pa - pb) * 100, 2),
                "only_a": only_a, "only_b": only_b, "discordant": only_a + only_b,
                "mcnemar_exact_p": round(_mcnemar_exact(only_a, only_b), 6),
                # The bit that decides the policy: escalation can only recover on a nested pair, and
                # cannot reach the union on a crossing one.
                "structure": structure,
                "escalation_can_reach_union": structure.startswith("nested") or structure == "identical",
            }
    return out


def merge(table: dict | None, run, run_dir: Path, cells: Iterable[str] | None = None,
          score_version: str = "v1") -> dict:
    """Fold one run's quality cells into the table, refusing a mismatched item set.

    The score version is a parameter because a scorer can be corrected after the fact, and the table has to
    be able to hold the corrected opinion rather than the first one. The summarisation family shipped its
    first run under thresholds that ranked the document's own opening above the human reference summary; the
    replies were fine and only the verdicts were wrong, so what belongs in the table is `v2`.
    """
    table = table or {"schema": SCHEMA, "runs": [], "suites": {}}
    wanted = set(cells) if cells else None
    for cell in run.cells:
        if cell.kind != "quality" or (wanted and cell.id not in wanted):
            continue
        ingested = ingest_cell(run_dir, cell.id, score_version)
        if not ingested["verdicts"]:
            continue
        suite_id = cell.suite.id
        suite = table["suites"].setdefault(suite_id, {
            "family": cell.suite.family,
            "items_provenance": getattr(cell.suite, "items_provenance", None),
            "item_ids": sorted(ingested["verdicts"]),
            "items_fingerprint": _fingerprint(ingested["verdicts"]),
            "layers": {},
        })
        fp = _fingerprint(ingested["verdicts"])
        if fp != suite["items_fingerprint"]:
            raise ValueError(
                f"{cell.id}: item set does not match suite {suite_id} "
                f"({fp} vs {suite['items_fingerprint']}). A layer measured on different items cannot be "
                f"merged — that is how four incomparable rates get averaged into a ranking.")
        suite["layers"][cell.layer.id] = {
            "model": cell.layer.model,
            "score_version": score_version,
            "kind": cell.layer.kind,
            "pricing_status": cell.layer.pricing_status,
            "run_id": run.id,
            "caveats": layer_caveats(cell.layer),
            **ingested,
        }
        suite["pairs"] = pairs_for(suite["layers"])
    if run.id not in table["runs"]:
        table["runs"].append(run.id)
    return table


def frontier(suite: dict, *, alpha: float = 0.05, latency_ratio: float = 1.10) -> list[dict]:
    """Layers not dominated on quality, cost and latency, where every leg of the domination is real.

    The first version of this compared quality and cost only, and treated any difference as a difference.
    On this suite it then reported the box as dominated by gemma-4 — on a quality gap of 1.4 points with
    p = 0.597 over 278 shared items, and a cost gap of 8% where gemma-4's price is a placeholder, while the
    box answers nine times faster. Every leg of that was an artifact.

    So domination now requires all three of:

    * **quality**: at least as good, and if better, better *significantly* — the stored pairwise McNemar
      p must be under `alpha`. An insignificant edge is not an edge.
    * **cost**: no more expensive, and never using a `pricing_placeholder` layer's price to dominate,
      because a made-up number cannot displace a measured one.
    * **latency**: no slower by more than `latency_ratio`. The project asks for three axes and a
      two-axis frontier silently discards the one the box wins by an order of magnitude.

    The effect is that the frontier gets wider and more honest. Being on it means "nothing here is clearly
    better on every axis", which is the question a router should ask, rather than "nothing here has a
    larger number somewhere".
    """
    layers = suite.get("layers", {})
    pairs = suite.get("pairs", {})
    if not layers:
        return []
    common = [k for k in suite["item_ids"]
              if all(l["verdicts"].get(k) is not None for l in layers.values())]
    rows = []
    for name, l in layers.items():
        if not common:
            continue
        rate = sum(l["verdicts"][k] for k in common) / len(common)
        rows.append({"layer": name, "n_common": len(common), "rate": round(rate, 4),
                     "usd_per_item": l["cost"]["usd_per_scored_item"],
                     "cost_basis": l["cost"]["basis"],
                     "cost_is_placeholder": l.get("pricing_status") == "placeholder",
                     "latency_p50_s": l["latency_s"]["p50"],
                     "caveats": l["caveats"]})

    def pair(a: str, b: str) -> dict:
        return pairs.get(f"{a}|{b}") or pairs.get(f"{b}|{a}") or {}

    for r in rows:
        r["dominated_by"] = []
        for o in rows:
            if o["layer"] == r["layer"]:
                continue
            d = pair(o["layer"], r["layer"])
            n = d.get("n") or 0
            # The point estimate must not be worse. Using significance in this direction would be the
            # error of reading "not proven worse" as "not worse", and it inverted the whole frontier the
            # first time: a cheap fast layer at 0.923 was reported as dominating the best layer at 0.980
            # purely because their difference was not significant.
            if o["rate"] < r["rate"]:
                continue
            # An *advantage*, on the other hand, has to be real to count as one.
            quality_better = (o["rate"] > r["rate"]
                              and bool(n) and d.get("mcnemar_exact_p", 1.0) < alpha)
            oc, rc = o["usd_per_item"], r["usd_per_item"]
            cheaper = oc is not None and rc is not None and oc < rc
            if cheaper and o["cost_is_placeholder"]:
                cheaper = False                # a placeholder price may not displace a measured one
            cost_ok = oc is None or rc is None or oc <= rc or not cheaper
            if oc is not None and rc is not None and oc > rc:
                continue                       # o is more expensive: cannot dominate
            ol, rl = o["latency_p50_s"], r["latency_p50_s"]
            if ol and rl and ol > rl * latency_ratio:
                continue                       # o is meaningfully slower: cannot dominate
            strictly_better = quality_better or cheaper or (ol and rl and ol < rl / latency_ratio)
            if strictly_better and cost_ok:
                r["dominated_by"].append(o["layer"])
        r["on_frontier"] = not r["dominated_by"]
    return sorted(rows, key=lambda r: -r["rate"])
