"""Summarize every <out>/<target>/<recipe>/ run into one Markdown table.

From train.log. torchrun --tee forwards rank output in bursts, so the Unix time run_variant.sh prefixes
to each line is when the burst arrived; the trainer's own "[titan] <UTC time>" stamp is used instead
whenever a line has one:
  blocking_s   the trainer's "Finished <saving|staging> the checkpoint in X seconds" values (median)
  step_s       median time between consecutive "step:" metric lines, excluding steps that saved
From watch.jsonl (the storage-side watcher):
  complete_s   median time from a save starting ("Saving/Staging the checkpointer" line after step N)
               to step-N's metadata file appearing, i.e. when the checkpoint is really on disk
  gb           median checkpoint size in GB
  steps_6_20_s wall time from step 6 to step 20, which includes the saves at steps 10 and 15 and any
               wait for a previous asynchronous save to finish
"""
import datetime
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
    lines = []
    for l in raw.splitlines():
        if not re.match(r"^\d+\.\d+ ", l):
            continue
        t, body = l.split(" ", 1)
        m = re.search(r"\[titan\] (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d),(\d{3})", body)
        if m:
            dt = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc)
            t = dt.timestamp() + int(m.group(2)) / 1000
        lines.append((float(t), body))
    blocking = [float(m.group(1)) for _, l in lines for m in [re.search(r"Finished (?:saving|staging) the checkpoint in ([\d.]+) seconds", l)] if m]
    # Each save starts right after the metric line of the step it saves; pair them by step number.
    starts, cur = {}, None
    for t, l in lines:
        m = re.search(r"(?<!validate )step:\s*(\d+)\s+loss:", l)
        if m:
            cur = int(m.group(1))
        elif cur is not None and re.search(r"(Saving|Staging) the checkpointer\.", l):
            starts.setdefault(cur, t)
    steps = [(t, int(m.group(1))) for t, l in lines for m in [re.search(r"(?<!validate )step:\s*(\d+)\s+loss:", l)] if m]
    saved = {int(m.group(1)) for _, l in lines for m in [re.search(r"step-(\d+)", l)] if m}
    saved |= {s for _, s in steps if s % 5 == 0}
    # A step's time is the gap from the previous step's line; exclude gaps that contain a save.
    gaps = [b[0] - a[0] for a, b in zip(steps, steps[1:]) if b[1] == a[1] + 1 and a[1] not in saved and a[1] > 2]
    watch = [json.loads(l) for l in (d / "watch.jsonl").read_text().splitlines()] if (d / "watch.jsonl").exists() else []
    done = {w["step"]: w["metadata_seen"] for w in watch if w.get("metadata_seen")}
    complete = [done[k] - t for k, t in starts.items() if k in done]
    # torch_checkpointing logs its own lines instead: "Initiating checkpoint staging" when a save
    # starts and "Staging copy done." when the copy out of GPU memory is finished. It writes into a
    # temporary directory and renames it, so step-N appears only when the save is complete.
    tc_start = [t for t, l in lines if "Initiating checkpoint staging" in l]
    tc_done = [t for t, l in lines if "Staging copy done." in l]
    if not blocking and tc_start:
        blocking = [b - a for a, b in zip(tc_start, tc_done)]
        firsts = [w["first_seen"] for w in sorted(watch, key=lambda w: w["step"]) if w["step"] % 5 == 0]
        complete = [f - a for a, f in zip(tc_start, firsts)]
    med = lambda v: round(statistics.median(v), 2) if v else None
    first = {}
    for t, k in steps:
        first.setdefault(k, t)
    # Wall time from step 6 to step 20: the saves at steps 10 and 15, and any wait they cause, are included.
    window = round(first[20] - first[6], 1) if 6 in first and 20 in first else None
    rows.append({"target": d.parent.name, "recipe": d.name, "saves": len(blocking), "blocking_s": med(blocking), "steps_6_20_s": window,
                 "complete_s": med([c for c in complete if c == c]), "step_s": med(gaps),
                 "gb": med([w["bytes"] / 1e9 for w in watch if w.get("bytes")]),
                 "rc": (d / "rc.txt").read_text().strip() if (d / "rc.txt").exists() else "?"})
cols = ["target", "recipe", "rc", "saves", "blocking_s", "complete_s", "steps_6_20_s", "step_s", "gb"]
print("| " + " | ".join(cols) + " |")
print("|" + "---|" * len(cols))
for r in rows:
    print("| " + " | ".join(str(r[c]) for c in cols) + " |")
(root / "summary.json").write_text(json.dumps(rows, indent=1))
