"""Run one quality cell, and write the four artifacts it owes.

A quality cell is deterministic and shallow by construction — the spec refuses anything else — because
what it measures is `p_i`, the probability a layer meets the family's floor, and sampling noise in that
number is noise in the admission decision.

The artifacts are separate files rather than one because they have different lifetimes. `request` and
`response` are what happened and never change. `score` is an opinion about the response and is versioned,
so a scorer can be corrected without spending the layer again. `cost` is the accounting, and it keeps the
API ledger and the box ledger apart all the way to disk.
"""

from __future__ import annotations

import json
import time
from dataclasses import asdict
from pathlib import Path

from . import scorers
from .layers import LayerClient
from .spec import Cell


def run_quality_cell(
    cell: Cell,
    task,
    out_dir: Path,
    *,
    limit: int | None = None,
    score_version: str = "v1",
) -> dict:
    """Send every item once, and write request/response/score/cost."""
    out_dir.mkdir(parents=True, exist_ok=True)
    client = LayerClient(cell.layer)
    items = task.load(limit=limit)

    requests, responses, verdicts, costs = [], [], [], []
    api_usd = box_usd = box_seconds = 0.0
    unusable = 0
    started = time.perf_counter()

    for item in items:
        prompt = task.prompt(item)
        # The layer's budget wins when it declares one, because what a model needs to reach an answer is
        # a property of the model. The metric's protection against verbosity is the scorer's own
        # truncation, not this number, so raising it does not make scoring more generous.
        budget = cell.layer.answer_token_budget or task.max_tokens
        reply = client.complete(prompt, max_tokens=budget, temperature=0.0)
        cost = client.cost(reply)
        api_usd += cost.api_usd
        box_usd += cost.box_usd_at_full_utilisation
        box_seconds += cost.box_seconds

        # A multimodal prompt is a list of parts, so "characters" is the text in it plus a count of
        # attachments. Recording len() of the list would silently log 2 for every OCR item.
        if isinstance(prompt, str):
            prompt_chars, attachments = len(prompt), 0
        else:
            prompt_chars = sum(len(part.get("text", "")) for part in prompt)
            attachments = sum(1 for part in prompt if part.get("type") != "text")
        requests.append({"item_id": item.id, "cell_id": cell.id, "layer": cell.layer.id,
                         "length_bin": getattr(item, "length_bin", None),
                         "prompt_chars": prompt_chars, "attachments": attachments})
        responses.append({"item_id": item.id, "cell_id": cell.id, "layer": cell.layer.id,
                          "text": reply.text, "prompt_tokens": reply.prompt_tokens,
                          "completion_tokens": reply.completion_tokens,
                          "cached_prompt_tokens": reply.cached_prompt_tokens,
                          "answer_token_budget": budget,
                          "latency_s": round(reply.latency_s, 4),
                          "finish_reason": reply.finish_reason, "error": reply.error,
                          "attempts": reply.attempts})
        costs.append({"item_id": item.id, "cell_id": cell.id, "layer": cell.layer.id,
                      "api_usd": cost.api_usd, "box_usd_at_full_utilisation":
                      cost.box_usd_at_full_utilisation, "box_seconds": cost.box_seconds,
                      "detail": cost.detail})

        if not reply.usable:
            # The transport failed, so this item says nothing about the layer's quality. Recorded and
            # excluded rather than counted wrong: counting it charges the layer for the network.
            unusable += 1
            verdicts.append({"item_id": item.id, "cell_id": cell.id, "layer": cell.layer.id,
                             "passed": None, "excluded": "transport",
                             "detail": reply.error or "no answer"})
            continue
        verdict = task.score(item, reply.text)
        verdicts.append({"item_id": item.id, "cell_id": cell.id, "layer": cell.layer.id,
                         **{k: v for k, v in asdict(verdict).items() if k != "item_id"},
                         "excluded": None})

    _write(out_dir / "request.jsonl", requests)
    _write(out_dir / "response.jsonl", responses)
    _write(out_dir / f"score.{score_version}.jsonl", verdicts)
    _write(out_dir / "cost.jsonl", costs)

    scored = [v for v in verdicts if v.get("excluded") is None]
    passed = sum(1 for v in scored if v["passed"])
    summary = {
        "cell_id": cell.id,
        "layer": cell.layer.id,
        "family": cell.suite.family,
        "items": len(items),
        "scored": len(scored),
        "excluded_transport": unusable,
        "passed": passed,
        "rate": passed / len(scored) if scored else None,
        "wilson_lower_80": scorers.wilson_lower(passed, len(scored), 0.80) if scored else None,
        "api_usd": api_usd,
        "box_usd_at_full_utilisation": box_usd,
        "box_seconds": box_seconds,
        "wall_s": time.perf_counter() - started,
        "pricing_status": cell.layer.pricing_status,
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    return summary


def compare(box_dir: Path, baseline_dir: Path, *, margin_pp: float, confidence: float,
            score_version: str = "v1") -> scorers.PairedResult:
    """The paired comparison, over the items both layers actually answered.

    An item excluded on either side is dropped from both: a pair needs two answers, and keeping the half
    that exists would compare the box on easy items with the baseline on all of them.
    """
    box = _verdicts(box_dir, score_version)
    base = _verdicts(baseline_dir, score_version)
    shared = [k for k in box if k in base and box[k] is not None and base[k] is not None]
    shared.sort()
    return scorers.paired_non_inferiority(
        [box[k] for k in shared], [base[k] for k in shared],
        margin_pp=margin_pp, confidence=confidence,
    )


def _verdicts(directory: Path, version: str) -> dict[str, bool | None]:
    out: dict[str, bool | None] = {}
    for line in (directory / f"score.{version}.jsonl").read_text().split("\n"):
        if not line.strip():
            continue
        row = json.loads(line)
        out[row["item_id"]] = None if row.get("excluded") else bool(row["passed"])
    return out


def _write(path: Path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
