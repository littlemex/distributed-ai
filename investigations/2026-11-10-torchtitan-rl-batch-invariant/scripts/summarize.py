"""Pull the per-step parity and timing metrics out of each run's console log into one table.

usage: summarize.py <out dir>   (expects <out>/<recipe>/train.log)
Prints, per recipe, the number of steps seen and the max over steps of bit_wise/logprob_diff/max,
the mean of bit_wise/ratio_tokens_different/mean, and the median step wall time when logged.
"""
import json
import re
import statistics
import sys
from pathlib import Path

KEYS = ["bit_wise/logprob_diff/max", "bit_wise/logprob_diff/mean", "bit_wise/ratio_tokens_different/mean"]
root = Path(sys.argv[1])
rows = []
for log in sorted(root.glob("*/train.log")):
    txt = re.sub(r"\x1b\[[0-9;]*m", "", log.read_text(errors="replace"))
    vals = {k: [float(m) for m in re.findall(re.escape(k) + r"[:=]\s*([-+0-9.eE]+)", txt)] for k in KEYS}
    step_t = [float(m) for m in re.findall(r"timing/(?:train_step|step)[^:=\s]*[:=]\s*([0-9.]+)", txt)]
    rows.append({"recipe": log.parent.name, "steps_logged": len(vals[KEYS[0]]),
                 "logprob_diff_max": max(vals[KEYS[0]]) if vals[KEYS[0]] else None,
                 "logprob_diff_mean": statistics.mean(vals[KEYS[1]]) if vals[KEYS[1]] else None,
                 "ratio_tokens_different": statistics.mean(vals[KEYS[2]]) if vals[KEYS[2]] else None,
                 "step_time_s_median": statistics.median(step_t) if step_t else None})
cols = list(rows[0]) if rows else []
print("| " + " | ".join(cols) + " |"); print("|" + "---|" * len(cols))
for r in rows:
    print("| " + " | ".join(str(r[c]) for c in cols) + " |")
(root / "summary.json").write_text(json.dumps(rows, indent=1))
