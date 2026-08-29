#!/usr/bin/env python3
"""Fetch a category-stratified OCRBench sample, and write it where measurements can reach it.

OCRBench is 1,000 items over several source datasets and five question types, with the answer given as a
list of acceptable strings — its official metric is whether any of them appears in the prediction, case
folded. That makes it exact-matchable without a judge, which is why it is a usable family rather than
another suite that needs an opinion to score.

The sample is stratified by the source dataset rather than drawn at random, because the point of adding
this family is to find out where the frontier *swaps*: printed text and simple layouts are expected to sit
differently from tables, charts and handwriting, and a random 200 would under-represent the small
categories that carry that signal.

Images go to the artifact volume and not to git. The manifest carries the question, the accepted answers,
the category and a path, so the run spec stays reviewable while a few hundred JPEGs do not enter history.
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import random
import sys
from collections import Counter, defaultdict
from pathlib import Path

DATASET = "echo840/OCRBench"


def load_rows():
    try:
        from datasets import load_dataset
    except ImportError:
        print("needs `datasets`: pip install datasets pillow", file=sys.stderr)
        raise
    return load_dataset(DATASET, split="test")


def stratified(rows, per_category: int, seed: int) -> list[int]:
    """Indices, `per_category` from each source dataset, seeded so a rerun gives the same sample."""
    buckets: dict[str, list[int]] = defaultdict(list)
    for i, r in enumerate(rows):
        buckets[r["dataset"]].append(i)
    rng = random.Random(seed)
    picked: list[int] = []
    for name in sorted(buckets):
        idx = buckets[name][:]
        rng.shuffle(idx)
        picked.extend(sorted(idx[:per_category]))
    return picked


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="directory on the artifact volume")
    ap.add_argument("--per-category", type=int, default=12)
    ap.add_argument("--seed", type=int, default=20260828)
    ap.add_argument("--max-edge", type=int, default=1600,
                    help="downscale the long edge; 0 keeps originals")
    a = ap.parse_args()

    rows = load_rows()
    picked = stratified(rows, a.per_category, a.seed)
    out = Path(a.out)
    (out / "images").mkdir(parents=True, exist_ok=True)

    manifest, cats, types, bytes_total = [], Counter(), Counter(), 0
    for n, i in enumerate(picked):
        r = rows[i]
        img = r["image"].convert("RGB")
        if a.max_edge and max(img.size) > a.max_edge:
            scale = a.max_edge / max(img.size)
            img = img.resize((max(1, int(img.width * scale)), max(1, int(img.height * scale))))
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=90)
        raw = buf.getvalue()
        name = f"{i:05d}.jpg"
        (out / "images" / name).write_bytes(raw)
        bytes_total += len(raw)
        manifest.append({
            "id": f"ocrbench-{i:05d}",
            "category": r["dataset"],
            "question_type": r["question_type"],
            "question": r["question"],
            # A list, and the official metric accepts any of them.
            "answers": list(r["answer"]),
            "image": f"images/{name}",
            "image_bytes": len(raw),
            "width": img.width, "height": img.height,
        })
        cats[r["dataset"]] += 1
        types[r["question_type"]] += 1

    (out / "manifest.jsonl").write_text(
        "".join(json.dumps(m, ensure_ascii=False) + "\n" for m in manifest))
    summary = {"dataset": DATASET, "seed": a.seed, "per_category": a.per_category,
               "max_edge": a.max_edge, "items": len(manifest),
               "image_bytes_total": bytes_total,
               "image_bytes_median": sorted(m["image_bytes"] for m in manifest)[len(manifest)//2],
               "categories": dict(cats), "question_types": dict(types)}
    (out / "sample.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
