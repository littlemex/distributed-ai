#!/usr/bin/env python3
"""Fetch long government reports for the summarisation family, stratified by document length.

GovReport rather than CNN/DailyMail or XSum on purpose. The reason this family is worth measuring is that
a single-shot summary of a *long* document has a long prefill and no prefix reuse, so the API's cache
discount does not apply — which is the one regime where the box measured 3.0x cheaper rather than 1.76x
more expensive. A short-input summarisation set would test the opposite thing.

Stratified by length rather than sampled at random, because the whole question is how the comparison moves
with input length, and a random draw from a heavy-tailed distribution mostly returns the mode.

A minimum length is enforced, not preferred. The scorer rejects a "summary" longer than a quarter of its
source as a copy, and on a short document no summary can both carry the facts and clear that bar — the
gate is only meaningful when the document is genuinely long.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path

DATASET = "ccdv/govreport-summarization"
MIN_DOC_CHARS = 8_000


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--per-bin", type=int, default=20)
    ap.add_argument("--seed", type=int, default=20260828)
    ap.add_argument("--max-doc-chars", type=int, default=120_000,
                    help="cap so one report cannot dominate the bill or exceed a window")
    a = ap.parse_args()

    from datasets import load_dataset
    rows = load_dataset(DATASET, split="test")

    # Length bins in characters, so the sample spans the range instead of clustering at the mode.
    bins = [(8_000, 20_000), (20_000, 40_000), (40_000, 80_000), (80_000, a.max_doc_chars)]
    buckets: dict[tuple[int, int], list[int]] = {b: [] for b in bins}
    for i, r in enumerate(rows):
        n = len(r["report"])
        if n < MIN_DOC_CHARS or n > a.max_doc_chars:
            continue
        for lo, hi in bins:
            if lo <= n < hi:
                buckets[(lo, hi)].append(i)
                break

    import random
    rng = random.Random(a.seed)
    picked: list[int] = []
    for b in bins:
        idx = buckets[b][:]
        rng.shuffle(idx)
        picked.extend(sorted(idx[: a.per_bin]))

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    items, doc_lens, ref_lens = [], [], []
    for i in picked:
        r = rows[i]
        items.append({"id": f"govreport-{i:05d}", "document": r["report"],
                      "reference": r["summary"],
                      "document_chars": len(r["report"]), "reference_chars": len(r["summary"]),
                      "length_bin": next(lo for lo, hi in bins if lo <= len(r["report"]) < hi)})
        doc_lens.append(len(r["report"]))
        ref_lens.append(len(r["summary"]))

    (out / "items.jsonl").write_text(
        "".join(json.dumps(it, ensure_ascii=False) + "\n" for it in items))
    summary = {
        "dataset": DATASET, "seed": a.seed, "per_bin": a.per_bin, "items": len(items),
        "min_doc_chars": MIN_DOC_CHARS, "max_doc_chars": a.max_doc_chars,
        "document_chars": {"min": min(doc_lens), "median": statistics.median(doc_lens),
                           "max": max(doc_lens), "total": sum(doc_lens)},
        "reference_chars": {"median": statistics.median(ref_lens)},
        "by_bin": {f"{lo}-{hi}": sum(1 for it in items if it["length_bin"] == lo)
                   for lo, hi in bins},
        # What this will cost to send once, so the bill is a decision rather than a surprise.
        "approx_input_tokens_total": sum(doc_lens) // 4,
    }
    (out / "sample.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
