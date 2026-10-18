"""Build the six data charts from data/models.csv, data/llm_extra.csv and data/rollout_share.csv into figures/."""
import csv, math, re, sys, os
import statistics as st
from datetime import date
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
import matplotlib.ticker

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = os.path.join(ROOT, "data")
OUT = os.path.join(ROOT, "figures")
os.makedirs(OUT, exist_ok=True)

BG, INK, MUTED, GRID = "#000000", "#f0efec", "#9a9990", "#2a2a28"
BLUE, ORANGE, AQUA, GREY = "#3987e5", "#d95926", "#199e70", "#6b6a64"
plt.rcParams.update({"figure.facecolor": BG, "axes.facecolor": BG, "savefig.facecolor": BG,
                     "text.color": INK, "axes.labelcolor": INK, "xtick.color": MUTED, "ytick.color": MUTED,
                     "axes.edgecolor": GRID, "font.size": 15, "axes.titlesize": 22, "axes.titleweight": "bold",
                     "font.family": ["Helvetica Neue", "Arial", "DejaVu Sans"]})


def num(x):
    try:
        v = float(str(x).replace(",", ""))
        return v if v > 0 else None
    except (TypeError, ValueError):
        return None


def rel(x):
    m = re.match(r"(\d{4})-(\d{1,2})", str(x or ""))
    return date(int(m.group(1)), int(m.group(2)), 15) if m else None


def year(x):
    m = re.match(r"(\d{4})", str(x or ""))
    return int(m.group(1)) if m else None


def norm(name):
    return re.sub(r"[^a-z0-9.+]", "", name.lower().replace("llama-", "llama").replace("meta", ""))


EXCLUDE = re.compile(r"vision|vl\b|-vl|omni|\u84b8\u7559|distill|reward|embedding|nemotron super|nemotron ultra|bakeneko|exaone deep|swallow|v3\.2-exp|flan|u-palm|instructgpt|minerva|guard|goat|lmsi|blenderbot|mt0|coedit|ditto|bluumi|vega v2|retrieval", re.I)
NOTEX = re.compile(r"CPT|\u7d99\u7d9a\u4e8b\u524d\u5b66\u7fd2|continued pre|continual pre|fine-tun|post-train only", re.I)
rows = {}
for r in csv.DictReader(open(f"{D}/models.csv")):
    if EXCLUDE.search(r["model"]) or NOTEX.search(r.get("notes") or ""):
        continue
    rows[norm(r["model"])] = dict(model=r["model"], release=rel(r["release"]), year=year(r["release"]), arch=(r["arch"] or "").lower(),
                                  total=num(r["total_b"]), active=num(r["active_b"]) or (num(r["total_b"]) if (r["arch"] or "").lower() == "dense" else None),
                                  tokens=num(r["pretrain_tokens_t"]), gpuh=num(r["pretrain_gpu_hours_m"]), gpu=r["pretrain_gpu"],
                                  src="primary", rl=num(r["rl_gpu_hours_k"]), rlkind=r["rl_gpu_hours_kind"], rlgpu=r["rl_gpu"], rlcount=r["rl_gpu_count"])
for r in csv.DictReader(open(f"{D}/llm_extra.csv")):
    k = norm(r["model"])
    if EXCLUDE.search(r["model"]) or k in rows or NOTEX.search(r.get("notes") or ""):
        continue
    if r["source_kind"] == "epoch" and ((num(r["total_b"]) or 0) < 1 or (num(r["tokens_t"]) or 0) < 0.05):
        continue
    arch = (r["arch"] or "").lower()
    rows[k] = dict(model=r["model"], release=rel(r["release"]), year=year(r["release"]), arch=arch, total=num(r["total_b"]),
                   active=num(r["active_b"]) or (num(r["total_b"]) if arch in ("dense", "") else None),
                   tokens=num(r["tokens_t"]), gpuh=num(r["gpu_hours_m"]), gpu=r["gpu"],
                   src="epoch" if r["source_kind"] == "epoch" else "primary", rl=None)
R = list(rows.values())
print("merged", len(R), "with params+tokens", sum(1 for r in R if r["total"] and r["tokens"]))

LABEL = ["GPT-3", "Chinchilla", "Llama 2 70B", "Llama 3.1 405B", "Llama 4 Scout", "DeepSeek-V3",
         "GLM-4.5-Air", "Kimi K2", "OLMo 3 32B", "Nemotron-4 340B", "PLaMo-100B", "Falcon 180B", "Reflection AI Beam", "SmolLM3"]
OFF = {"Llama 4 Scout": (8, -14), "DeepSeek-V3": (8, -14), "Kimi K2": (8, 6), "GLM-4.5-Air": (-40, -18), "Reflection AI Beam": (8, -14), "Chinchilla": (-78, -4),
       "Nemotron-4 340B": (8, -12), "PLaMo-100B": (8, 6), "Llama 3.1 405B": (8, -14), "Falcon 180B": (8, -12), "Llama 2 70B": (-80, 6)}


def pick_labels(points, skip=()):
    out = []
    for lab in LABEL:
        if lab in skip:
            continue
        key = norm(lab)
        best = [p for p in points if key in norm(p["model"])]
        if best:
            out.append((lab, best[0]))
    return out


def style(ax, title, sub):
    ax.set_title(title, loc="left", pad=40, color=INK)
    ax.text(0, 1.035, sub, transform=ax.transAxes, color=MUTED, fontsize=14)
    ax.grid(True, which="major", color=GRID, linewidth=0.8)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)


def save(fig, name):
    fig.savefig(f"{OUT}/{name}.png", dpi=110, bbox_inches="tight", pad_inches=0.4)
    plt.close(fig)
    print("wrote", name)


def is_moe(p):
    a = p["arch"]
    if "moe" in a:
        return True
    return "hybrid" in a and p["active"] and p["total"] and p["active"] < p["total"] * 0.9


def moe_with_tokens(points):
    return [p for p in points if p["src"] == "primary" and is_moe(p) and p["active"] and p["total"] and p["tokens"] and p["year"]]


def series(points):
    prim = [p for p in points if p["src"] == "primary" and p["arch"]]
    moe = [p for p in prim if is_moe(p)]
    dense = [p for p in prim if not is_moe(p)]
    other = [p for p in points if p["src"] == "epoch" or not p["arch"]]
    return dense, moe, other


# RL post-training GPU-hours (thousands) drawn in chart 4
RL = []
for r in csv.DictReader(open(f"{D}/models.csv")):
    v = num(r["rl_gpu_hours_k"])
    if not v or v < 1 or re.search(r"sea-lion|phi-4|t\u00fclu 3 8b|tulu 3 8b|olmo 3 32b$|vision|\u84b8\u7559|nemotron 3.5", r["model"], re.I):
        continue
    kind = "reported" if r["rl_gpu_hours_kind"] == "reported" else "computed"
    name = r["model"]
    cnt = r["rl_gpu_count"]
    if name.startswith("INTELLECT-3"):
        cnt = "512 (allocation)"
    if "Olmo 3.1" in name:
        name = "Olmo 3.1 Think 32B (extra 21 days)"
    if name == "DeepSeek-V3":
        name = "DeepSeek-V3 (all post-training)"
    RL.append(dict(model=name, rl=v, rlkind=kind, rlgpu=r["rl_gpu"], rlcount=cnt))
RL.sort(key=lambda r: r["rl"])


# ---------------- 1. total params vs tokens
P = [r for r in R if r["total"] and r["tokens"]]
dense, moe, epoch = series(P)
fig, ax = plt.subplots(figsize=(13.4, 7.6))
for k, ls in ((20, "--"), (200, ":"), (2000, "-.")):
    xs = [0.1, 3000]
    ax.plot(xs, [x * k / 1000 for x in xs], ls, color=MUTED, linewidth=1.2, zorder=1)
    xl = {20: 1.5, 200: 0.25, 2000: 0.25}[k]
    ax.text(xl, xl * k / 1000 * 1.35, f"{k} tokens / param", color=MUTED, fontsize=12)
ax.scatter([p["total"] for p in epoch], [p["tokens"] for p in epoch], s=46, facecolors="none", edgecolors=GREY, linewidths=1.2, label=f"Epoch AI database or arch unknown ({len(epoch)})", zorder=2)
ax.scatter([p["total"] for p in dense], [p["tokens"] for p in dense], s=70, color=BLUE, edgecolors=BG, linewidths=1.5, label=f"dense, primary source ({len(dense)})", zorder=3)
ax.scatter([p["total"] for p in moe], [p["tokens"] for p in moe], s=80, marker="D", color=ORANGE, edgecolors=BG, linewidths=1.5, label=f"MoE incl. hybrid MoE, primary source ({len(moe)})", zorder=4)
for lab, p in pick_labels(dense + moe, skip=("Kimi K2", "Reflection AI Beam", "GLM-4.5-Air")):
    ax.annotate(lab, (p["total"], p["tokens"]), xytext={"Llama 3.1 405B": (-40, -20)}.get(lab, OFF.get(lab, (6, 4))), textcoords="offset points", fontsize=11, color=INK, zorder=6, bbox=dict(boxstyle="round,pad=0.15", fc=BG, ec="none", alpha=0.75))
ax.set_xscale("log"); ax.set_yscale("log")
ax.set_xlim(0.1, 3000); ax.set_ylim(0.01, 80)
ax.set_xlabel("total parameters (billion)")
ax.set_yticks([0.01, 0.1, 1, 10, 40])
ax.set_yticklabels(["10B tok\n~40 GB", "100B tok\n~0.4 TB", "1T tok\n~4 TB", "10T tok\n~40 TB", "40T tok\n~160 TB"])
ax.set_ylabel("pre-training tokens (bytes at ~4 B/token, model)")
style(ax, "Parameters vs pre-training tokens", "LLMs 2018–2026. Bytes assume ~4 bytes per token of filtered text")
leg = ax.legend(loc="lower left", frameon=False, fontsize=12)
save(fig, "params-vs-tokens")

# ---------------- 2. release vs tokens per active param
P = [r for r in R if r["active"] and r["tokens"] and r["release"]]
dense, moe, epoch = series(P)
fig, ax = plt.subplots(figsize=(13.4, 7.2))
tpa = lambda p: p["tokens"] * 1000 / p["active"]
ax.axhline(20, color=MUTED, linestyle="--", linewidth=1.2)
ax.text(date(2018, 3, 1), 24, "Chinchilla ~20 tokens / param", color=MUTED, fontsize=12)
ax.scatter([p["release"] for p in epoch], [tpa(p) for p in epoch], s=46, facecolors="none", edgecolors=GREY, linewidths=1.2, label="Epoch AI database or arch unknown", zorder=2)
ax.scatter([p["release"] for p in dense], [tpa(p) for p in dense], s=70, color=BLUE, edgecolors=BG, linewidths=1.5, label="dense, primary source", zorder=3)
ax.scatter([p["release"] for p in moe], [tpa(p) for p in moe], s=80, marker="D", color=ORANGE, edgecolors=BG, linewidths=1.5, label="MoE incl. hybrid MoE, primary source", zorder=4)
for lab, p in pick_labels(dense + moe):
    ax.annotate(lab, (p["release"], tpa(p)), xytext=OFF.get(lab, (6, 4)), textcoords="offset points", fontsize=11, color=INK, zorder=6, bbox=dict(boxstyle="round,pad=0.15", fc=BG, ec="none", alpha=0.75))
ax.set_yscale("log"); ax.set_ylim(0.5, 60000)
ax.xaxis.set_major_locator(mdates.YearLocator()); ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y"))
ax.set_ylabel("pre-training tokens per active parameter")
style(ax, "Models train far past compute-optimal", "Tokens per active parameter by release date")
ax.legend(loc="upper left", frameon=False, fontsize=12)
save(fig, "tokens-per-param-by-date")

# ---------------- 3. compute vs reported GPU-hours (Hopper-class only, same bf16 peak)
HOP = re.compile(r"H100|H800|H200", re.I)
P = [r for r in R if r["active"] and r["tokens"] and r["gpuh"] and HOP.search(r["gpu"] or "") and not re.search(r"think", r["model"], re.I) and r["src"] == "primary"]
dense, moe, epoch = series(P)
fig, ax = plt.subplots(figsize=(13.4, 7.6))
peak = 0.9895e15
xs = [1e21, 1e26]
for mfu in (0.1, 0.2, 0.4):
    ax.plot(xs, [x / (peak * mfu * 3600) / 1e6 for x in xs], "--", color=MUTED, linewidth=1.1)
    ax.text(1.6e21, 1.6e21 / (peak * mfu * 3600) / 1e6 * 1.25, f"{int(mfu*100)}%", color=MUTED, fontsize=13)
for grp, col, mk, lab in ((dense, BLUE, "o", "dense, primary source"), (moe, ORANGE, "D", "MoE, primary source")):
    xv = [6 * p["active"] * 1e9 * p["tokens"] * 1e12 for p in grp]
    yv = [p["gpuh"] for p in grp]
    if grp is epoch and not grp:
        continue
    if grp is epoch:
        ax.scatter(xv, yv, s=46, facecolors="none", edgecolors=col, linewidths=1.2, label=lab)
    else:
        ax.scatter(xv, yv, s=80, marker=mk, color=col, edgecolors=BG, linewidths=1.5, label=lab, zorder=3)
for lab, p in pick_labels(dense + moe):
    ax.annotate(lab, (6 * p["active"] * 1e9 * p["tokens"] * 1e12, p["gpuh"]), xytext=OFF.get(lab, (6, 4)), textcoords="offset points", fontsize=11, zorder=6, bbox=dict(boxstyle="round,pad=0.15", fc=BG, ec="none", alpha=0.75))
ax.set_xscale("log"); ax.set_yscale("log"); ax.set_xlim(1e21, 1e26)
ax.set_xlabel("pre-training compute 6 · N_active · D (FLOP)")
ax.set_ylabel("reported GPU-hours (million)")
style(ax, "Compute vs reported GPU-hours on H100 / H800 / H200", f"{len(P)} models. Dashed: GPU-hours at 10 / 20 / 40% of the 0.99 PFLOP/s bf16 peak (model)")
ax.legend(loc="upper left", frameon=False, fontsize=12)
save(fig, "compute-vs-gpu-hours")

# ---------------- 4. RL GPU-hours
fig, ax = plt.subplots(figsize=(13.4, 7.4))
ys = range(len(RL))
cols = [INK if r["rlkind"] == "reported" else AQUA for r in RL]
ax.barh(list(ys), [r["rl"] * 1000 for r in RL], color=cols, height=0.62)
for y, r in zip(ys, RL):
    ax.text(r["rl"] * 1000 * 1.12, y, f"{r['rl']*1000/1e3:,.0f}K  ·  {r['rlgpu']} {r['rlcount']}".replace("K  ·   ", "K"), va="center", fontsize=12, color=INK)
ax.set_yticks(list(ys)); ax.set_yticklabels([r["model"] for r in RL], color=INK, fontsize=13)
ax.set_xscale("log"); ax.set_xlim(500, 6e7)
ax.set_xlabel("RL post-training GPU-hours (log)")
from matplotlib.patches import Patch
ax.legend(handles=[Patch(color=INK, label="reported"), Patch(color=AQUA, label="computed from GPU count × days (allocation)")], loc="lower right", frameon=False, fontsize=12)
style(ax, "RL post-training compute in public reports", "GPU-hours as reported, or GPUs × days when only those are given")
ax.grid(axis="y", visible=False)
save(fig, "rl-gpu-hours")

# ---------------- 5. rollout share
S = list(csv.DictReader(open(f"{D}/rollout_share.csv")))
CITED = ("ROLL Flash", "Jet-RL")
BOUND = ("APRIL", "ReSpec", "Laminar", "OpenRLHF")
by, kind = {}, {}
for s_ in S:
    name = s_["system"]
    if name.startswith(CITED):
        continue
    name = name.replace("HybridFlow baseline (NeMo-Aligner)", "NeMo-Aligner (HybridFlow baseline)")
    v = [num(s_["rollout_share_min_pct"]), num(s_["rollout_share_max_pct"])]
    by.setdefault(name, []).extend([x for x in v if x])
    kind[name] = "bound" if name.startswith(BOUND) else "measured"
items = sorted(by.items(), key=lambda kv: max(kv[1]))
fig, ax = plt.subplots(figsize=(13.4, 6.8))
for y, (name, vals) in enumerate(items):
    lo, hi = min(vals), max(vals)
    hollow = kind[name] == "bound"
    if hi - lo > 0.5:
        ax.plot([lo, hi], [y, y], color=BLUE, linewidth=4, solid_capstyle="round")
    ax.scatter(vals, [y] * len(vals), s=80, facecolors=BG if hollow else BLUE, edgecolors=BLUE, linewidths=2, zorder=3)
    lab = f"{lo:.0f}–{hi:.0f}%" if hi - lo > 0.5 else f"{hi:.0f}%"
    ax.text(hi + 1.5, y, ("≥ " if name.startswith(("APRIL", "ReSpec", "OpenRLHF")) else "≤ " if name.startswith("Laminar") else "") + lab, va="center", fontsize=12)
ax.set_yticks(range(len(items))); ax.set_yticklabels([k for k, _ in items], color=INK, fontsize=13)
ax.axvline(20, color=ORANGE, linestyle="--", linewidth=1.4)
ax.set_ylim(-1.2, len(items) - 0.5)
ax.text(21, -0.9, "rollout share of FLOPs ≈ 20% (model)", color=ORANGE, fontsize=12)
ax.set_xlim(0, 105); ax.set_xlabel("rollout share of RL iteration time (%)")
style(ax, "Rollout share of RL step time by system", "Filled: measured or computed setting. Hollow: bound or general statement quoted in the paper")
ax.grid(axis="y", visible=False)
save(fig, "rollout-share")


# ---------------- 6. MoE active share by release year
M = moe_with_tokens(R)
years = (2024, 2025, 2026)
fig, ax = plt.subplots(figsize=(13.4, 6.8))
for i, y in enumerate(years):
    v = [p["active"] / p["total"] * 100 for p in sorted((p for p in M if p["year"] == y), key=lambda p: p["model"])]
    xs = [i + ((j * 0.618) % 1 - 0.5) * 0.5 for j in range(len(v))]
    ax.scatter(xs, v, s=80, color=ORANGE, edgecolors=BG, linewidths=1.5, zorder=3)
    med = st.median(v)
    ax.plot([i - 0.32, i + 0.32], [med, med], color=INK, linewidth=2.5, zorder=4)
    ax.text(i + 0.36, med, f"median {med:.1f}%  (n={len(v)})", va="center", fontsize=13, color=INK, zorder=5, bbox=dict(boxstyle="round,pad=0.2", fc=BG, ec="none"))
ax.set_yscale("log")
ax.set_yticks([2, 5, 10, 20, 50]); ax.set_yticklabels(["2%", "5%", "10%", "20%", "50%"])
ax.yaxis.set_minor_formatter(matplotlib.ticker.NullFormatter())
ax.set_xticks(range(len(years))); ax.set_xticklabels([str(y) for y in years], color=INK)
ax.set_xlim(-0.6, len(years) - 0.1); ax.set_ylim(1.5, 60)
ax.set_ylabel("active / total parameters")
style(ax, "MoE models activate a shrinking share of their parameters", "MoE models with disclosed pre-training tokens, primary sources, by release year")
ax.grid(axis="x", visible=False)
save(fig, "moe-active-share-by-year")
