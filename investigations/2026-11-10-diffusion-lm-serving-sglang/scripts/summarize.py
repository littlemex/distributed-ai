"""One table per run label: decode throughput and latency from bench_serving, accuracy from GSM8K.

usage: summarize.py <out dir>   (expects <out>/<label>/bench.jsonl and gsm8k.txt)
"""
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
rows = []
for d in sorted(p for p in root.iterdir() if p.is_dir()):
    acc = None
    g = d / "gsm8k.txt"
    if g.exists():
        m = re.findall(r"Accuracy:\s*([0-9.]+)", g.read_text(errors="replace"))
        acc = float(m[-1]) if m else None
    b = d / "bench.jsonl"
    for line in (b.read_text().splitlines() if b.exists() else []):
        r = json.loads(line)
        rows.append({"label": d.name, "concurrency": r.get("max_concurrency"),
                     "output_tok_s": round(r.get("output_throughput", 0), 1),
                     "ttft_ms_p50": round(r.get("median_ttft_ms", 0), 1),
                     "itl_ms_p50": round(r.get("median_itl_ms", 0), 2),
                     "e2e_ms_p50": round(r.get("median_e2e_latency_ms", 0), 1),
                     "gsm8k_acc": acc})
    if not b.exists():
        rows.append({"label": d.name, "concurrency": None, "output_tok_s": None, "ttft_ms_p50": None,
                     "itl_ms_p50": None, "e2e_ms_p50": None, "gsm8k_acc": acc})
cols = ["label", "concurrency", "output_tok_s", "ttft_ms_p50", "itl_ms_p50", "e2e_ms_p50", "gsm8k_acc"]
print("| " + " | ".join(cols) + " |"); print("|" + "---|" * len(cols))
for r in rows:
    print("| " + " | ".join(str(r[c]) for c in cols) + " |")
(root / "summary.json").write_text(json.dumps(rows, indent=1))
