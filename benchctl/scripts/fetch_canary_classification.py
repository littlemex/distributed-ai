"""Build the classification canary, and be honest about what it is.

`p_i` is defined on the traffic the box would actually serve, so a canary should be a held-out sample of
production requests. There is no production traffic for this family yet, so this pulls a public
Japanese review-sentiment set instead. That makes the run a proof of the path and NOT admissible
evidence for routing: the number it produces describes reviews from an open dataset, and admission has
to be re-measured on held-out traffic once there is any. The manifest records that, so nobody reads the
number as more than it is.

Stratified by input length because the box's economics depend on it: reading is where the box is four
times cheaper than the cheapest API, and writing is where it is barely cheaper at all.
"""

from __future__ import annotations

import argparse
import json
import urllib.parse
import urllib.request
from pathlib import Path

DATASET = "tyqiangz/multilingual-sentiments"
CONFIG = "japanese"
SPLIT = "test"
ROWS = "https://datasets-server.huggingface.co/rows?dataset={d}&config={c}&split={s}&offset={o}&length={n}"
# The dataset ships integer labels; this is its documented order.
LABELS = {"0": "ポジティブ", "1": "ニュートラル", "2": "ネガティブ"}
# The neutral class is a three-star rating rather than a judgement, and a first run showed every miss on
# both layers landing there while positive and negative were perfect. A suite that only separates layers
# on the ambiguous class measures the label convention, so it is droppable and dropped by default.
DROPPABLE = ("ニュートラル",)
BINS = (256, 1024, 4096)


def bin_of(text: str) -> int:
    for edge in BINS:
        if len(text) <= edge:
            return edge
    return BINS[-1]


def fetch(offset: int, length: int) -> list[dict]:
    url = ROWS.format(d=urllib.parse.quote(DATASET, safe=""), c=CONFIG, s=SPLIT, o=offset, n=length)
    with urllib.request.urlopen(url, timeout=120) as response:
        return [row["row"] for row in json.load(response)["rows"]]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=Path("specs/items/classification-ja-public-v1.jsonl"))
    ap.add_argument("--per-bin", type=int, default=20, help="items per length bin per label")
    ap.add_argument("--keep-neutral", action="store_true",
                    help="keep the three-star class. Off by default: see DROPPABLE")
    ap.add_argument("--scan", type=int, default=1200, help="how many rows to read while stratifying")
    ap.add_argument("--split-rows", type=int, default=3000, help="rows in the split, for spreading")
    args = ap.parse_args()

    wanted: dict[tuple[int, str], list[dict]] = {}
    seen: set[str] = set()
    # Spread the offsets across the whole split. The first few hundred rows of this one are a single
    # label, so reading from the front returns a set with two of the three classes missing -- a canary
    # that cannot detect the failure mode it exists to detect.
    pages = max(1, args.scan // 100)
    stride = max(100, (args.split_rows - 100) // pages)
    for offset in range(0, pages * stride, stride):
        for row in fetch(min(offset, args.split_rows - 100), 100):
            text = (row.get("text") or "").strip()
            label = LABELS.get(str(row.get("label")))
            if not text or not label or text in seen:
                continue
            if label in DROPPABLE and not args.keep_neutral:
                continue
            seen.add(text)
            key = (bin_of(text), label)
            bucket = wanted.setdefault(key, [])
            if len(bucket) < args.per_bin:
                bucket.append({"text": text, "label": label, "length_bin": key[0]})

    items = []
    for (length_bin, label), bucket in sorted(wanted.items()):
        for i, row in enumerate(bucket):
            items.append({"id": f"ja-{length_bin}-{label}-{i:03d}", **row})

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(json.dumps(i, ensure_ascii=False) for i in items) + "\n")
    counts: dict[tuple, int] = {}
    for i in items:
        counts[(i["length_bin"], i["label"])] = counts.get((i["length_bin"], i["label"]), 0) + 1
    print(f"[OK] {len(items)} items -> {args.out}")
    for key in sorted(counts):
        print(f"     bin<={key[0]:>5}  {key[1]:<12} {counts[key]}")
    kept = "3 classes" if args.keep_neutral else "2 classes (the three-star class dropped)"
    print(f"[NOTE] {kept}. A public dataset, not held-out production traffic: this proves the path, "
          "and the rate it yields is not admissible evidence for routing")


if __name__ == "__main__":
    main()
