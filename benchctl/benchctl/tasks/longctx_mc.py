"""Long context in, one letter out.

The family the box's economics actually favour. Reading is where it is four times cheaper than the
cheapest API and writing is where it is barely cheaper at all, so the saving per request scales with the
input, and here the input is tens of thousands of tokens against an output of one character.

Four-way choice rather than free extraction, for one reason: the answer is exact-matchable, so the
evaluation needs no judge and the judge's cost never contaminates the serving ledger. The cost of that
choice is that a wrong answer tells you less than a wrong span would.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

from .. import scorers

CHOICES = ("A", "B", "C", "D")


@dataclass(frozen=True)
class Item:
    id: str
    context: str
    question: str
    choices: dict
    label: str
    difficulty: str = ""
    length_bin: int | None = None


PROMPT = """次の文書を読み、質問に答えてください。

回答は A / B / C / D のいずれか 1 文字のみ。理由や説明は書かないこと。

--- 文書 ---
{context}
--- 文書ここまで ---

質問: {question}

A. {a}
B. {b}
C. {c}
D. {d}

回答:"""


class LongContextChoice:
    name = "tasks.longctx_mc"
    # One letter, plus room for the punctuation a model insists on adding.
    max_tokens = 6

    def __init__(self, items_path: Path, labels: tuple[str, ...] = CHOICES) -> None:
        self.items_path = Path(items_path)
        self.labels = labels

    def load(self, limit: int | None = None) -> list[Item]:
        out: list[Item] = []
        # split("\n") and not splitlines(): JSON escapes real newlines, but str.splitlines() also
        # breaks on U+2028, U+2029, \x0b and friends, which json.dumps leaves raw with
        # ensure_ascii=False. A long document containing one of those split a record in half.
        for line in self.items_path.read_text().split("\n"):
            if not line.strip():
                continue
            raw = json.loads(line)
            out.append(Item(id=raw["id"], context=raw["context"], question=raw["question"],
                            choices=raw["choices"], label=raw["label"].strip().upper(),
                            difficulty=raw.get("difficulty", ""), length_bin=raw.get("length_bin")))
            if limit and len(out) >= limit:
                break
        return out

    def prompt(self, item: Item) -> str:
        return PROMPT.format(context=item.context, question=item.question,
                             a=item.choices["A"], b=item.choices["B"],
                             c=item.choices["C"], d=item.choices["D"])

    def score(self, item: Item, answer: str | None) -> scorers.Verdict:
        # A model that answers "The answer is B." has answered B. Taking the first standalone letter is
        # the parse, and anything with no letter at all counts as unparseable rather than as wrong -- the
        # distinction matters because a format failure is fixable and a wrong choice is not.
        text = (answer or "").strip()
        match = re.search(r"\b([ABCD])\b", text.upper())
        picked = match.group(1) if match else None
        return scorers.Verdict(
            item_id=item.id,
            passed=picked == item.label,
            predicted=picked or (text[:40] or None),
            expected=item.label,
            detail="" if picked else "no A-D letter in the answer",
        )
