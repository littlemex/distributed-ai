"""Short-input enum classification.

The first family to be admitted, and not because the money is here — the box's input is a quarter of
the cheapest API's while its output is only 18% cheaper, so the saving scales with input length and
this family has short inputs. It is first because it is the cheapest way to prove the whole path:
items, prompt, parse, score, paired statistic, cost ledger, artifact layout, fallback.

The answer is one of a fixed set, so scoring needs no judge and no reference model, and a wrong answer
is caught by a validator in production rather than discovered later.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from .. import scorers


@dataclass(frozen=True)
class Item:
    id: str
    text: str
    label: str
    length_bin: int | None = None


PROMPT = """次のレビュー文の感情を分類してください。

回答は {labels} のいずれか 1 語のみ。説明や記号は付けないこと。

レビュー:
{text}

回答:"""


class ClassificationEnum:
    """One family: items from a JSONL file, a fixed label set, exact-match scoring."""

    name = "tasks.classification_enum"

    def __init__(self, items_path: Path, labels: tuple[str, ...]) -> None:
        self.items_path = Path(items_path)
        self.labels = labels

    def load(self, limit: int | None = None) -> list[Item]:
        out: list[Item] = []
        for line in self.items_path.read_text().splitlines():
            if not line.strip():
                continue
            raw = json.loads(line)
            out.append(Item(id=str(raw["id"]), text=raw["text"], label=str(raw["label"]),
                            length_bin=raw.get("length_bin")))
            if limit and len(out) >= limit:
                break
        return out

    def prompt(self, item: Item) -> str:
        return PROMPT.format(labels=" / ".join(self.labels), text=item.text)

    # Enough for one word plus whatever punctuation a model insists on adding. Kept small so that a
    # model which starts explaining is truncated rather than paid for.
    max_tokens = 8

    def score(self, item: Item, answer: str | None) -> scorers.Verdict:
        verdict = scorers.exact_label(answer, item.label, allowed=self.labels)
        return scorers.Verdict(item_id=item.id, passed=verdict.passed, predicted=verdict.predicted,
                               expected=verdict.expected, detail=verdict.detail)
