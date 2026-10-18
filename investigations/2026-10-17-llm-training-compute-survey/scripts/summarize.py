"""Print the summary statistics quoted in the article (token counts by size and year, implied MFU, rollout share)."""
import csv
import math
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
print(f"release year recorded: n={sum(1 for r in P if r['release'])}")
for y in (2020, 2021, 2022, 2023, 2024, 2025, 2026):
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

print("\n# RL post-training GPU-hours (thousands), the bars of rl-gpu-hours.png")
describe("RL GPU-hours (K)", [r["rl"] for r in g["RL"]])

print("\n# MoE with disclosed pre-training tokens: active / total parameters (%) by release year, primary sources")
for y in (2024, 2025, 2026):
    describe(f"{y}", [r["active"] / r["total"] * 100 for r in g["moe_with_tokens"](R) if r["year"] == y])

# Chinchilla loss fit replicated by Besiroglu et al. (arXiv:2404.10102)
E, A, B, a, b = 1.8172, 482.01, 2085.43, 0.3478, 0.3658
loss = lambda N, D: E + A / N ** a + B / D ** b
G = (a * A / (b * B)) ** (1 / (a + b))


def optimal_compute_for(target):
    lo, hi = 1e15, 1e32
    for _ in range(200):
        mid = math.sqrt(lo * hi)
        N = G * (mid / 6) ** (b / (a + b))
        lo, hi = (lo, mid) if loss(N, mid / 6 / N) < target else (mid, hi)
    return math.sqrt(lo * hi)


print("\n# Dense models: compute used / compute reaching the same fitted loss at the compute-optimal split, primary sources")
tax = []
for r in R:
    if r["src"] != "primary" or g["is_moe"](r) or not (r["active"] and r["tokens"] and r["release"]):
        continue
    N, Dt = r["active"] * 1e9, r["tokens"] * 1e12
    C = 6 * N * Dt
    tax.append((C / optimal_compute_for(loss(N, Dt)), N < G * (C / 6) ** (b / (a + b))))
describe("compute ratio", [t for t, _ in tax])
print(f"smaller than the compute-optimal size for the same compute: {sum(s for _, s in tax)} of {len(tax)}")

print("\n# Artificial Analysis Intelligence Index of releases sharing one pre-training run")
for r in csv.DictReader(open(os.path.join(g["D"], "aa_mapping_audited.csv"))):
    print(f"{r['base_model'][:24]:24s} {r['aa_name'][:36]:36s} {r['aa_date']} index={float(r['aa_index']):5.1f} same_pretrain={r['same_pretrain_weights']} extra_tokens_T={r['extra_pretrain_tokens_t']}")
