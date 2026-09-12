"""OCRBench: read an image, answer a question, be scored without a judge.

The family the project was told was mandatory, and the one where the box has the largest unmeasured
quantity: it carries a vision tower, and not one second of vision box-time has been measured. Nothing
from the text work extrapolates here — image tokens have their own prefill profile, the encoder is a
separate cost, and whether the kernel-efficiency ceiling found for hybrid attention also holds in the
vision path is unknown.

Scoring follows OCRBench's own rule rather than inventing one: an answer counts if any of the accepted
strings appears in the prediction, case folded and whitespace normalised. Two deliberate departures,
both recorded on every verdict so a score can be recomputed differently without re-spending a layer:

* **Mathematical expression recognition is exact-match after normalisation**, as in the official
  implementation, because substring matching on LaTeX passes almost anything.
* **A prediction is truncated to a length budget before matching.** Substring matching rewards
  verbosity — a model that lists twenty guesses hits by accident — and the official harness relies on
  short outputs rather than guarding against it. This is the only guard; `max_tokens` is not, and using it
  as one truncated a reasoning model to silence on 38 items.
"""

from __future__ import annotations

import base64
import json
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path

from .. import scorers

# The category whose official scoring is exact-match rather than containment.
EXACT_MATCH_CATEGORIES = ("HME100k",)

PROMPT = ("Read the image and answer the question.\n"
          "Answer with the value only — no explanation, no punctuation, no restating the question.\n\n"
          "Question: {question}\nAnswer:")


@dataclass(frozen=True)
class Item:
    id: str
    category: str
    question_type: str
    question: str
    answers: tuple[str, ...]
    image_path: Path
    image_bytes: int
    width: int
    height: int
    length_bin: int | None = None


def _normalise(s: str) -> str:
    """Case fold, fold width, collapse whitespace. Nothing cleverer, so it stays predictable."""
    s = unicodedata.normalize("NFKC", s or "").casefold()
    return re.sub(r"\s+", " ", s).strip()


class OcrVqa:
    """One family: a manifest of image questions with accepted answers, scored by containment."""

    name = "tasks.ocr_vqa"

    # The default for a layer that declares no budget of its own. It used to be 48, chosen to stop
    # containment scoring being gamed by verbosity, and that was the wrong tool: it truncated opus-5 to
    # empty on 38 of 278 items while `match_budget` below was already doing the job properly. Raised, and
    # layers that need more say so in the spec.
    max_tokens = 256
    # Characters of prediction considered when matching, after normalisation.
    match_budget = 200

    def __init__(self, manifest_path: Path, image_root: Path | None = None) -> None:
        self.manifest_path = Path(manifest_path)
        self.image_root = Path(image_root) if image_root else self.manifest_path.parent

    def load(self, limit: int | None = None) -> list[Item]:
        out: list[Item] = []
        for line in self.manifest_path.read_text().split("\n"):
            if not line.strip():
                continue
            raw = json.loads(line)
            out.append(Item(
                id=str(raw["id"]), category=raw["category"],
                question_type=raw["question_type"], question=raw["question"],
                answers=tuple(raw["answers"]),
                image_path=self.image_root / raw["image"],
                image_bytes=int(raw.get("image_bytes", 0)),
                width=int(raw.get("width", 0)), height=int(raw.get("height", 0)),
            ))
            if limit and len(out) >= limit:
                break
        return out

    def prompt(self, item: Item) -> list[dict]:
        """Text plus one inline image, as OpenAI content parts.

        The image is inlined as a data URI rather than served over a URL because the box has no route
        to fetch one and a URL would make the two layers do different work.
        """
        b64 = base64.b64encode(item.image_path.read_bytes()).decode()
        return [
            {"type": "text", "text": PROMPT.format(question=item.question)},
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
        ]

    def score(self, item: Item, answer: str | None) -> scorers.Verdict:
        pred_raw = answer or ""
        pred = _normalise(pred_raw)[: self.match_budget]
        exact = item.category in EXACT_MATCH_CATEGORIES
        matched = None
        for candidate in item.answers:
            gold = _normalise(candidate)
            if not gold:
                continue
            if (pred == gold) if exact else (gold in pred):
                matched = candidate
                break
        return scorers.Verdict(
            item_id=item.id, passed=matched is not None,
            predicted=pred_raw[:300], expected=" | ".join(item.answers),
            detail=json.dumps({
                "rule": "exact" if exact else "containment",
                "matched": matched, "category": item.category,
                "question_type": item.question_type,
                "truncated_for_match": len(_normalise(pred_raw)) > self.match_budget,
                "image_bytes": item.image_bytes,
                "image_px": f"{item.width}x{item.height}",
            }, ensure_ascii=False),
        )
