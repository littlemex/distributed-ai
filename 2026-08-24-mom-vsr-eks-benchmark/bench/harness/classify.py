"""What the router would decide, without paying a model to answer.

The router exposes its classification API separately from the data path, and it
returns the decision, the matched domain, the confidence and the model the
selector would name. So two things that look like they need a full run are free:

* the classifier's own accuracy against the dataset's true category, which is the
  term that separates "the assignment policy was wrong" from "the classifier sent
  the question to the wrong policy";
* the distribution of models `multi_factor` names, which is how the claim that a
  static quality score cannot express per-domain strength gets tested rather than
  asserted.

A routed arm still has to be executed for real — the selector's latency and load
factors move with live traffic, and end-to-end latency and failures only exist on
the data path. This is the cheap prior, not a substitute.
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Sequence

import aiohttp

from . import dataset


@dataclass
class Decision:
    question_id: str
    category: str
    fold: str
    matched_domains: list[str]
    decision_name: str | None
    confidence: float | None
    recommended_model: str | None
    processing_time_ms: float | None
    error: str | None = None

    def to_json(self) -> dict:
        return asdict(self)


async def classify_one(
    session: aiohttp.ClientSession, url: str, item: dataset.Item, timeout_s: float = 60.0
) -> Decision:
    decision = Decision(
        question_id=item.question_id,
        category=item.category,
        fold=item.fold,
        matched_domains=[],
        decision_name=None,
        confidence=None,
        recommended_model=None,
        processing_time_ms=None,
    )
    try:
        async with session.post(
            url,
            json={"text": item.prompt},
            headers={"content-type": "application/json"},
            timeout=aiohttp.ClientTimeout(total=timeout_s),
        ) as response:
            text = await response.text()
            if response.status != 200:
                decision.error = f"http {response.status}: {text[:200]}"
                return decision
            payload = json.loads(text)
    except Exception as exc:  # noqa: BLE001 - recorded, not swallowed
        decision.error = f"{type(exc).__name__}: {exc}"[:300]
        return decision

    classification = payload.get("classification") or {}
    result = payload.get("decision_result") or {}
    decision.decision_name = result.get("decision_name") or payload.get(
        "routing_decision"
    )
    decision.confidence = result.get("confidence") or classification.get("confidence")
    decision.recommended_model = payload.get("recommended_model")
    decision.processing_time_ms = classification.get("processing_time_ms")
    decision.matched_domains = list(
        (payload.get("matched_signals") or {}).get("domains") or []
    )
    return decision


async def classify_all(
    url: str,
    items: Sequence[dataset.Item],
    out_path: Path,
    *,
    concurrency: int = 8,
) -> list[Decision]:
    """Classify every item, streaming each decision to disk as it lands.

    Streamed rather than collected because the classifier shares a CPU limit with
    the router's request path: while a measurement run is in flight this pass
    slows to a crawl, and a run that is interrupted should leave behind the
    decisions it did make rather than nothing.
    """
    out_path.parent.mkdir(parents=True, exist_ok=True)
    semaphore = asyncio.Semaphore(concurrency)
    write_lock = asyncio.Lock()
    results: list[Decision] = []

    with out_path.open("w") as sink:

        async def one(session: aiohttp.ClientSession, item: dataset.Item) -> None:
            async with semaphore:
                decision = await classify_one(session, url, item)
            results.append(decision)
            async with write_lock:
                sink.write(json.dumps(decision.to_json(), ensure_ascii=False) + "\n")
                sink.flush()

        connector = aiohttp.TCPConnector(limit=concurrency + 4)
        async with aiohttp.ClientSession(connector=connector) as session:
            await asyncio.gather(*(one(session, item) for item in items))

    return results
