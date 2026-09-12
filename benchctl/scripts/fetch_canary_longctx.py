"""Build the long-context canary: real long documents, a four-way choice, a one-letter answer.

This is the shape the box is supposed to win: the saving comes from input tokens, and here the input is
tens of thousands of them while the output is one letter. Verifiable without a judge, which keeps the
evaluation cost out of the serving ledger.

LongBench-v2's contexts run to a million characters, past this deployment's 262k-token window, so the
window is filtered rather than truncated -- a truncated context can make an answerable question
unanswerable, and then the measurement is of the truncation.
"""

from __future__ import annotations

import argparse
import json
import urllib.parse
import urllib.request
from pathlib import Path

DATASET = "zai-org/LongBench-v2"
ROWS = "https://datasets-server.huggingface.co/rows?dataset={d}&config=default&split=train&offset={o}&length={n}"
CHOICES = ("A", "B", "C", "D")


def fetch(offset: int, length: int) -> list[dict]:
    url = ROWS.format(d=urllib.parse.quote(DATASET, safe=""), o=offset, n=length)
    with urllib.request.urlopen(url, timeout=180) as response:
        return [row["row"] for row in json.load(response)["rows"]]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=Path("specs/items/longctx-mc-v1.jsonl"))
    ap.add_argument("--min-chars", type=int, default=20000)
    ap.add_argument("--max-chars", type=int, default=100000)
    ap.add_argument("--per-difficulty", type=int, default=15)
    ap.add_argument("--scan", type=int, default=300)
    args = ap.parse_args()

    buckets: dict[str, list[dict]] = {}
    for offset in range(0, args.scan, 50):
        for row in fetch(offset, 50):
            context = row.get("context") or ""
            if not (args.min_chars <= len(context) <= args.max_chars):
                continue
            answer = (row.get("answer") or "").strip().upper()
            if answer not in CHOICES:
                continue
            difficulty = row.get("difficulty") or "unknown"
            bucket = buckets.setdefault(difficulty, [])
            if len(bucket) >= args.per_difficulty:
                continue
            bucket.append({
                "id": str(row.get("_id"))[:24],
                "context": context,
                "question": row.get("question") or "",
                "choices": {c: row.get(f"choice_{c}") or "" for c in CHOICES},
                "label": answer,
                "difficulty": difficulty,
                "domain": row.get("domain"),
                "length_bin": len(context) // 20000 * 20000,
            })

    items = [i for bucket in buckets.values() for i in bucket]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("".join(json.dumps(i, ensure_ascii=False) + "\n" for i in items))

    print(f"[OK] {len(items)} items -> {args.out}")
    for difficulty, bucket in sorted(buckets.items()):
        chars = sorted(len(i["context"]) for i in bucket)
        print(f"     {difficulty:<8} {len(bucket):>3} items, context median {chars[len(chars)//2]:,} chars")
    total = sum(len(i["context"]) for i in items)
    print(f"     total context {total:,} chars, roughly {total//4:,} tokens per layer per pass")
    print("[NOTE] a public benchmark, not held-out production traffic. It proves the shape and the "
          "economics; p_i for a real workload has to be measured on that workload")


if __name__ == "__main__":
    main()
