"""Print the summary statistics quoted in the article (token counts by size and year, implied MFU, rollout share)."""
import csv
import os
import re
import statistics as st
import sys

sys.argv = [sys.argv[0]]
HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "build_charts.py")).read().split("# ---------------- 1.")[0]
g = {"__file__": os.path.join(HERE, "build_charts.py")}
exec(src, g)
R = g["R"]


def describe(name, values):
    v = sorted(values)
    if not v:
        print(f"{name}: n=0")
        return
    q = lambda f: v[min(len(v) - 1, int(f * len(v)))]
    print(f"{name}: n={len(v)} median={st.median(v):.3g} q1={q(0.25):.3g} q3={q(0.75):.3g} min={v[0]:.3g} max={v[-1]:.3g}")


P = [r for r in R if r["src"] == "primary" and r["total"] and r["tokens"]]
print("# Pre-training tokens (T), primary sources")
for lo, hi, lab in ((0, 10, "<10B"), (10, 100, "10-100B"), (100, 1e9, ">=100B")):
    b = [r for r in P if lo <= r["total"] < hi]
    describe(f"{lab} total params", [r["tokens"] for r in b])
    describe(f"{lab} total params, released 2025 or later", [r["tokens"] for r in b if r["release"] and r["release"].year >= 2025])
for y in (2023, 2024, 2025, 2026):
    describe(f"released in {y}", [r["tokens"] for r in P if r["release"] and r["release"].year == y])
describe("tokens per active parameter, released 2025 or later",
         [r["tokens"] * 1000 / r["active"] for r in R if r["src"] == "primary" and r["active"] and r["tokens"] and r["release"] and r["release"].year >= 2025])

print("\n# 6 * N_active * D over reported GPU-hours, as % of the 0.9895 PFLOP/s bf16 peak (H100 / H800 / H200)")
H = [r for r in R if r["active"] and r["tokens"] and r["gpuh"] and re.search("H100|H800|H200", r["gpu"] or "")
     and not re.search("think", r["model"], re.I) and r["src"] == "primary"]
describe("implied bf16 peak ratio %", [6 * r["active"] * 1e9 * r["tokens"] * 1e12 / (r["gpuh"] * 1e6 * 3600 * 0.9895e15) * 100 for r in H])

print("\n# Rollout share of RL iteration time (%), measured or computed settings only")
S = [x for x in csv.DictReader(open(os.path.join(g["D"], "rollout_share.csv")))
     if not x["system"].startswith(("ROLL Flash", "Jet-RL", "APRIL", "ReSpec", "Laminar", "OpenRLHF"))]
describe("rollout share %", [float(x["rollout_share_max_pct"]) for x in S])
