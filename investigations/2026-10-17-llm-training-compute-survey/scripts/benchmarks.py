"""Regress base-model benchmark scores on pre-training compute and tokens per active parameter, and draw the coefficient chart.

The scores are the unified re-evaluation of base models by Ruan et al. (arXiv:2405.10938), joined in data/bench_joined.csv.
data/bench_joined_fixes.csv corrects values that disagree with the model's own paper or model card.
"""
import collections
import csv
import os
import sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = os.path.join(ROOT, "data")
OUT = os.path.join(ROOT, "figures")
BENCHES = ("MMLU", "GSM8K", "HellaSwag", "Winogrande")
CHANCE = {"MMLU": .25, "ARC-Challenge": .25, "HellaSwag": .25, "Winogrande": .5, "GSM8K": 0.0, "TruthfulQA": .25,
          "HumanEval": 0.0, "XWinograd": .5, "BBH": .25, "GPQA": .25, "IFEval": 0.0, "MATH-Lvl5": 0.0, "MMLU-PRO": .1, "MUSR": .33}
B = 2000

fixes = {(r["model"], r["field"]): float(r["new"]) for r in csv.DictReader(open(f"{D}/bench_joined_fixes.csv"))}
family = {r["model"]: (r["lineage"], float(r["release_year"])) for r in csv.DictReader(open(f"{D}/bench_model_family_year.csv"))}

groups = collections.defaultdict(dict)
for r in csv.DictReader(open(f"{D}/bench_joined.csv")):
    if not (r["active_b"] and r["tokens_t"] and r["score"]) or "Observational Scaling" not in r["source"]:
        continue
    if r["model"] not in family:
        sys.exit(f"no lineage for {r['model']} in bench_model_family_year.csv")
    if r["model"] in groups[r["benchmark"]]:
        sys.exit(f"duplicate score for {r['model']} on {r['benchmark']}")
    fam, yr = family[r["model"]]
    groups[r["benchmark"]][r["model"]] = dict(
        N=fixes.get((r["model"], "active_b"), float(r["active_b"])) * 1e9,
        D=fixes.get((r["model"], "tokens_t"), float(r["tokens_t"])) * 1e12,
        y=float(r["score"]), family=fam, year=yr)
groups = {k: list(v.values()) for k, v in groups.items() if len(v) >= 25}


def design(rows, with_year):
    cols = [np.ones(len(rows)), [np.log10(6 * r["N"] * r["D"]) for r in rows], [np.log10(r["D"] / r["N"]) for r in rows]]
    if with_year:
        cols.append([r["year"] - 2022 for r in rows])
    return np.column_stack(cols), np.array([r["y"] for r in rows])


def fit(rows, with_year=False, cluster=True, seed=0):
    """Coefficient of log10(tokens / active param) in points, with a 95% percentile bootstrap interval and the two-sided bootstrap sign proportion as p."""
    rng = np.random.default_rng(seed)
    X, y = design(rows, with_year)
    b = np.linalg.lstsq(X, y, rcond=None)[0][2]
    units = collections.defaultdict(list)
    for i, r in enumerate(rows):
        units[r["family"] if cluster else i].append(i)
    keys = list(units)
    boots = []
    for _ in range(B):
        idx = [i for k in rng.choice(len(keys), len(keys)) for i in units[keys[k]]]
        Xb, yb = X[idx], y[idx]
        if np.linalg.matrix_rank(Xb) == X.shape[1]:
            boots.append(np.linalg.lstsq(Xb, yb, rcond=None)[0][2])
    boots = np.array(boots)
    lo, hi = np.percentile(boots, [2.5, 97.5])
    k = len(boots)
    p = min(1.0, 2 * min((1 + np.sum(boots <= 0)) / (k + 1), (1 + np.sum(boots >= 0)) / (k + 1)))
    return dict(b=b * 100, lo=lo * 100, hi=hi * 100, p=p, n=len(rows), fam=len(keys) if cluster else len({r["family"] for r in rows}), dropped=B - k)


def above_floor(rows, bench):
    c = CHANCE[bench]
    return [r for r in rows if r["y"] > c + (0.03 if c > 0 else 0.02)]


def holm(p):
    order = np.argsort(p)
    adj, run = np.empty(len(p)), 0.0
    for rank, i in enumerate(order):
        run = max(run, p[i] * (len(p) - rank))
        adj[i] = min(run, 1.0)
    return adj


names = sorted(groups)
for cluster in (False, True):
    fits = [fit(groups[k], cluster=cluster) for k in names]
    adj = holm(np.array([f["p"] for f in fits]))
    unit = "lineage-cluster" if cluster else "model-level"
    print(f"# All benchmarks, {unit} bootstrap, Holm-adjusted p over {len(names)} benchmarks")
    for k, f, a in zip(names, fits, adj):
        print(f"{k:14s} n={f['n']:3d} lineages={f['fam']:2d} {f['b']:+5.1f} pt [{f['lo']:+.1f}, {f['hi']:+.1f}] p={f['p']:.3f} p_holm={a:.3f} dropped={f['dropped']}")
    print()

CONDITIONS = (
    ("all models", lambda rows, k: rows, False),
    ("near-chance scores removed", above_floor, False),
    ("release year added", lambda rows, k: [r for r in rows if r["year"] is not None], True),
    ("near-chance removed, year added", lambda rows, k: [r for r in above_floor(rows, k) if r["year"] is not None], True),
)
res = {}
print("\n# Per 10x tokens per active parameter at fixed compute, lineage-cluster bootstrap")
for k in BENCHES:
    for label, select, with_year in CONDITIONS:
        rows = select(groups[k], k)
        res[(k, label)] = f = fit(rows, with_year=with_year)
        print(f"{k:11s} {label:31s} n={f['n']:3d} lineages={f['fam']:2d} {f['b']:+5.1f} pt [{f['lo']:+.1f}, {f['hi']:+.1f}] dropped={f['dropped']}")
dated = [r for r in groups["MMLU"] if r["year"] is not None]
years = [r["year"] for r in dated]
print(f"\nMMLU group: release years {min(years):.0f}-{max(years):.0f}, median {np.median(years):.1f}")
for name, v in (("log10(D/N)", [np.log10(r["D"] / r["N"]) for r in dated]), ("log10(6ND)", [np.log10(6 * r["N"] * r["D"]) for r in dated])):
    print(f"Pearson correlation of release year and {name}: {np.corrcoef(years, v)[0, 1]:.2f} (n={len(dated)})")

BG, INK, MUTED, GRID = "#000000", "#f0efec", "#9a9990", "#2a2a28"
COLORS = {"all models": "#3987e5", "near-chance scores removed": "#d95926", "release year added": "#199e70", "near-chance removed, year added": "#9b7fd4"}
plt.rcParams.update({"figure.facecolor": BG, "axes.facecolor": BG, "savefig.facecolor": BG, "text.color": INK,
                     "axes.labelcolor": INK, "xtick.color": MUTED, "ytick.color": MUTED, "axes.edgecolor": GRID,
                     "font.size": 15, "axes.titlesize": 22, "axes.titleweight": "bold",
                     "font.family": ["Helvetica Neue", "Arial", "DejaVu Sans"]})
fig, ax = plt.subplots(figsize=(13.4, 9.2))
ticks, labels = [], []
for i, k in enumerate(BENCHES):
    for j, (label, _, _) in enumerate(CONDITIONS):
        y = -(i * 5 + j)
        f = res[(k, label)]
        ax.plot([f["lo"], f["hi"]], [y, y], color=COLORS[label], linewidth=3, solid_capstyle="round")
        ax.scatter([f["b"]], [y], s=90, color=COLORS[label], edgecolors=BG, linewidths=2, zorder=3,
                   label=label if i == 0 else None)
        ax.text(max(f["hi"], f["b"]) + 0.6, y, f"{f['b']:+.1f}  (n={f['n']})", va="center", fontsize=12, color=INK)
    ticks.append(-(i * 5 + 1.5)); labels.append(k)
ax.axvline(0, color=MUTED, linewidth=1.2)
ax.set_yticks(ticks); ax.set_yticklabels(labels, color=INK, fontsize=15)
ax.set_xlabel("score change (points) per 10x tokens per active parameter, compute held fixed")
ax.set_xlim(-14, 30)
ax.set_title("At fixed compute, the effect of tokens per parameter is not identified", loc="left", pad=40, color=INK)
ax.text(0, 1.035, "~100 base models, one evaluation protocol (Ruan et al. 2024). Bars: 95% interval, resampling model lineages",
        transform=ax.transAxes, color=MUTED, fontsize=13)
ax.grid(True, axis="x", color=GRID, linewidth=0.8)
for s in ("top", "right"):
    ax.spines[s].set_visible(False)
ax.legend(loc="lower right", frameon=False, fontsize=12)
os.makedirs(OUT, exist_ok=True)
fig.savefig(f"{OUT}/tpp-effect-at-fixed-compute.png", dpi=110, bbox_inches="tight", pad_inches=0.4)
print("wrote tpp-effect-at-fixed-compute")
