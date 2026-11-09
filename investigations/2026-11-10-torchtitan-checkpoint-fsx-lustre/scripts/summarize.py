"""Summarize every <out>/<target>/<recipe>/ run into one Markdown table.

From train.log (each line prefixed with a Unix time by run_variant.sh):
  blocking_s   the trainer's "Finished <saving|staging> the checkpoint in X seconds" values (median)
  step_s       median time between consecutive "step:" metric lines, excluding steps that saved
From watch.jsonl (the storage-side watcher):
  complete_s   median time from a save starting ("Saving/Staging the checkpointer" line) to the
               step directory's metadata file appearing, i.e. when the checkpoint is really on disk
  gb           median checkpoint size in GB
"""
import json
import re
import statistics
import sys
from pathlib import Path

root = Path(sys.argv[1])
rows = []
for run in sorted(root.glob("*/*/train.log")):
    d = run.parent
    raw = re.sub(r"\x1b\[[0-9;]*m", "", run.read_text(errors="replace"))  # torchtitan colors its metric lines
    lines = [(float(l.split(" ", 1)[0]), l.split(" ", 1)[1]) for l in raw.splitlines() if re.match(r"^\d+\.\d+ ", l)]
    blocking = [float(m.group(1)) for _, l in lines for m in [re.search(r"Finished (?:saving|staging) the checkpoint in ([\d.]+) seconds", l)] if m]
    starts = [t for t, l in lines if re.search(r"(Saving|Staging) the checkpointer\.", l)]
    steps = [(t, int(m.group(1))) for t, l in lines for m in [re.search(r"(?<!validate )step:\s*(\d+)\s+loss:", l)] if m]
    gaps = [b[0] - a[0] for a, b in zip(steps, steps[1:]) if b[1] == a[1] + 1]
    watch = [json.loads(l) for l in (d / "watch.jsonl").read_text().splitlines()] if (d / "watch.jsonl").exists() else []
    done = sorted(w["metadata_seen"] for w in watch if w.get("metadata_seen"))
    complete = [min((x for x in done if x >= s), default=float("nan")) - s for s in starts]
    med = lambda v: round(statistics.median(v), 2) if v else None
    rows.append({"target": d.parent.name, "recipe": d.name, "saves": len(blocking), "blocking_s": med(blocking),
                 "complete_s": med([c for c in complete if c == c]), "step_s": med(gaps),
                 "gb": med([w["bytes"] / 1e9 for w in watch if w.get("bytes")]),
                 "rc": (d / "rc.txt").read_text().strip() if (d / "rc.txt").exists() else "?"})
cols = ["target", "recipe", "rc", "saves", "blocking_s", "complete_s", "step_s", "gb"]
print("| " + " | ".join(cols) + " |")
print("|" + "---|" * len(cols))
for r in rows:
    print("| " + " | ".join(str(r[c]) for c in cols) + " |")
(root / "summary.json").write_text(json.dumps(rows, indent=1))
