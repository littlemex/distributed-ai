#!/usr/bin/env python3
"""results/*.json から ブログ/スライド用の図を生成する。

出力先: figures/ (PNG, 150dpi)。英語ラベル (スライドが英語のため)、20pt+ フォント。
生成図:
  fig1_goodput_vs_concurrency : Bedrock vs 自前 (B/B0) の goodput-vs-concurrency (主役)
  fig2_cost_breakeven         : 従量課金 (Bedrock flat) vs インスタンス課金 (自前=achieved req/s で逓減) の損益分岐
  fig3_ttft_tpot              : TTFT/TPOT vs concurrency (Bedrock 崩壊 vs 自前安定)
  fig4_lora_vs_sysprompt      : B(LoRA) vs B0(system prompt) の throughput 対比 (反直感)
  fig5_routing                : round-robin vs affinity (賢いルーティング)
  fig6_longcontext            : 入力長 vs TTFT/goodput (自前の long-ctx 限界)
"""
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

plt.rcParams.update({
    "font.size": 20, "axes.titlesize": 22, "axes.labelsize": 20,
    "xtick.labelsize": 17, "ytick.labelsize": 17, "legend.fontsize": 17,
    "figure.dpi": 150, "savefig.bbox": "tight", "axes.grid": True, "grid.alpha": 0.3,
})
R = os.path.join(os.path.dirname(__file__), "..", "results")
OUT = os.path.join(os.path.dirname(__file__), "..", "figures")
os.makedirs(OUT, exist_ok=True)

# Capacity Block / Bedrock pricing (RUNLOG §7, DESIGN-v2 §7)
C_CB = 93.60          # $/hr, p6-b300.48xlarge Capacity Block
P_IN, P_OUT = 0.14, 0.40  # Bedrock Gemma 4 31B $/1M in, out


def load(name):
    return json.load(open(os.path.join(R, f"{name}.json")))["stages"]


def col(stages, key):
    return [s.get(key) for s in stages]


# ---- fig1: goodput vs concurrency (the headline) ----
def fig1():
    bed = load("bedrock-31b-512tok")
    b = load("B-roundrobin")
    b0 = load("B0-sysprompt")
    fig, ax = plt.subplots(figsize=(11, 7))
    ax.plot(col(b0, "concurrency"), col(b0, "goodput_req_s"), "o-", lw=3, ms=10,
            label="Self-host B0 (system prompt)", color="#1f77b4")
    ax.plot(col(b, "concurrency"), col(b, "goodput_req_s"), "s-", lw=3, ms=10,
            label="Self-host B (LoRA)", color="#2ca02c")
    ax.plot(col(bed, "concurrency"), col(bed, "goodput_req_s"), "^-", lw=3, ms=12,
            label="Bedrock Gemma 4 31B", color="#d62728")
    ax.set_xlabel("Concurrency (simultaneous requests)")
    ax.set_ylabel("Goodput (req/s within SLO)")
    ax.set_title("Goodput vs Concurrency  (TTFT<=2s, TPOT<=80ms)")
    ax.set_xscale("log", base=2)
    ax.legend(loc="upper left")
    ax.annotate("Bedrock collapses\n(queues, TTFT explodes)", xy=(32, 0.27), xytext=(60, 40),
                arrowprops=dict(arrowstyle="->", color="#d62728", lw=2), color="#d62728", fontsize=16)
    fig.savefig(os.path.join(OUT, "fig1_goodput_vs_concurrency.png"))
    plt.close(fig)


# ---- fig2: cost break-even ----
def fig2():
    # Bedrock per-1M-request cost (flat, no caching): S=512 sys + 10 user in, 64 out
    S, U, O = 512, 10, 64
    bedrock_per_req = ((S + U) * P_IN + O * P_OUT) / 1e6  # $ per request
    # Self-host cost per request = ($/hr) / (achieved_req_s * 3600)
    rps = list(range(10, 700, 5))
    selfcost = [C_CB / (r * 3600) for r in rps]
    fig, ax = plt.subplots(figsize=(11, 7))
    ax.plot(rps, [c * 1e6 for c in selfcost], "-", lw=3, color="#1f77b4",
            label="Self-host ($93.6/hr / achieved req/s)")
    ax.axhline(bedrock_per_req * 1e6, ls="--", lw=3, color="#d62728",
               label=f"Bedrock flat (${bedrock_per_req*1e6:.0f}/1M req)")
    # break-even
    be = C_CB / (bedrock_per_req * 3600)
    ax.axvline(be, ls=":", lw=2, color="gray")
    ax.annotate(f"break-even\n~{be:.0f} req/s", xy=(be, bedrock_per_req * 1e6),
                xytext=(be + 50, bedrock_per_req * 1e6 * 2.2), fontsize=16,
                arrowprops=dict(arrowstyle="->", lw=2))
    # measured saturation markers
    for label, r, color in [("B0 sat ~398", 398, "#1f77b4"), ("B sat ~110", 110, "#2ca02c")]:
        ax.plot([r], [C_CB / (r * 3600) * 1e6], "*", ms=22, color=color)
        ax.annotate(label, xy=(r, C_CB / (r * 3600) * 1e6), xytext=(r - 30, C_CB / (r * 3600) * 1e6 + 60),
                    fontsize=15, color=color)
    ax.set_xlabel("Self-host achieved goodput (req/s)")
    ax.set_ylabel("Cost ($ / 1M requests)")
    ax.set_title("Cost: Pay-per-token (Bedrock) vs Instance (self-host)\nS=512 system prompt, 64 out")
    ax.set_ylim(0, bedrock_per_req * 1e6 * 4)
    ax.legend(loc="upper right")
    fig.savefig(os.path.join(OUT, "fig2_cost_breakeven.png"))
    plt.close(fig)


# ---- fig3: TTFT / TPOT vs concurrency ----
def fig3():
    bed = load("bedrock-31b-512tok")
    b0 = load("B0-sysprompt")
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(15, 6.5))
    a1.plot(col(b0, "concurrency"), col(b0, "ttft_p90"), "o-", lw=3, ms=9, color="#1f77b4", label="Self-host B0")
    a1.plot(col(bed, "concurrency"), col(bed, "ttft_p90"), "^-", lw=3, ms=11, color="#d62728", label="Bedrock")
    a1.set_yscale("log"); a1.set_xscale("log", base=2)
    a1.set_xlabel("Concurrency"); a1.set_ylabel("TTFT p90 (ms)"); a1.set_title("TTFT p90 (log)")
    a1.legend(); a1.axhline(2000, ls=":", color="gray")
    a2.plot(col(b0, "concurrency"), col(b0, "tpot_p50"), "o-", lw=3, ms=9, color="#1f77b4", label="Self-host B0")
    a2.plot(col(bed, "concurrency"), col(bed, "tpot_p50"), "^-", lw=3, ms=11, color="#d62728", label="Bedrock")
    a2.set_xscale("log", base=2)
    a2.set_xlabel("Concurrency"); a2.set_ylabel("TPOT p50 (ms/token)"); a2.set_title("TPOT p50")
    a2.legend()
    fig.suptitle("Latency under load: Bedrock TTFT explodes, self-host stays flat", fontsize=20)
    fig.savefig(os.path.join(OUT, "fig3_ttft_tpot.png"))
    plt.close(fig)


# ---- fig4: LoRA vs system prompt (counter-intuitive) ----
def fig4():
    b = load("B-roundrobin")
    b0 = load("B0-sysprompt")
    fig, ax = plt.subplots(figsize=(11, 7))
    ax.plot(col(b0, "concurrency"), col(b0, "out_tok_per_s"), "o-", lw=3, ms=10,
            label="B0: base + system prompt", color="#1f77b4")
    ax.plot(col(b, "concurrency"), col(b, "out_tok_per_s"), "s-", lw=3, ms=10,
            label="B: multi-LoRA adapter", color="#2ca02c")
    ax.set_xlabel("Concurrency")
    ax.set_ylabel("Output throughput (tok/s)")
    ax.set_title("Counter-intuitive: system prompt > LoRA on self-host\n(multi-LoRA SGMV overhead, TPOT 18 vs 53ms)")
    ax.set_xscale("log", base=2)
    ax.legend(loc="upper left")
    fig.savefig(os.path.join(OUT, "fig4_lora_vs_sysprompt.png"))
    plt.close(fig)


# ---- fig5: routing round-robin vs affinity ----
def fig5():
    rr = load("B-roundrobin")
    aff = load("B-affinity")
    fig, ax = plt.subplots(figsize=(11, 7))
    ax.plot(col(rr, "concurrency"), col(rr, "goodput_req_s"), "s-", lw=3, ms=10,
            label="Round-robin (naive)", color="#ff7f0e")
    ax.plot(col(aff, "concurrency"), col(aff, "goodput_req_s"), "o-", lw=3, ms=10,
            label="Affinity (tenant->replica)", color="#1f77b4")
    ax.set_xlabel("Concurrency")
    ax.set_ylabel("Goodput (req/s)")
    ax.set_title("Smart routing (llm-d style): affinity +24% at saturation\n128 tenants, max_loras=32")
    ax.set_xscale("log", base=2)
    ax.legend(loc="upper left")
    ax.annotate("+24%", xy=(512, 121.6), xytext=(300, 121.6), fontsize=18, color="#1f77b4",
                arrowprops=dict(arrowstyle="->", lw=2, color="#1f77b4"))
    fig.savefig(os.path.join(OUT, "fig5_routing.png"))
    plt.close(fig)


# ---- fig6: long-context limit ----
def fig6():
    sizes = [1024, 4096, 8192, 16384, 30000]
    ttft, good = [], []
    for s in sizes:
        st = load(f"lc-in{s}")[0]
        ttft.append(st["ttft_p50"]); good.append(st["goodput_req_s"])
    fig, ax1 = plt.subplots(figsize=(11, 7))
    ax1.plot(sizes, ttft, "o-", lw=3, ms=10, color="#9467bd", label="TTFT p50 (ms)")
    ax1.set_xlabel("Input length (tokens)")
    ax1.set_ylabel("TTFT p50 (ms)", color="#9467bd")
    ax1.set_xscale("log", base=2); ax1.tick_params(axis="y", labelcolor="#9467bd")
    ax2 = ax1.twinx(); ax2.grid(False)
    ax2.plot(sizes, good, "s--", lw=3, ms=10, color="#1f77b4", label="Goodput (req/s)")
    ax2.set_ylabel("Goodput (req/s) @ conc 64", color="#1f77b4")
    ax2.tick_params(axis="y", labelcolor="#1f77b4")
    ax1.set_title("Self-host long-context: 30K tok in 2.6s, SLO 100%\n(8x B300, TPOT flat ~11-16ms)")
    fig.savefig(os.path.join(OUT, "fig6_longcontext.png"))
    plt.close(fig)


# ---- fig7: tenant-count scale — affinity lowers TTFT (routing value grows with tenants) ----
def fig7():
    nts = [32, 64, 128]
    rr_ttft = [load(f"scale-nt{n}-roundrobin")[0]["ttft_p50"] for n in nts]
    aff_ttft = [load(f"scale-nt{n}-affinity")[0]["ttft_p50"] for n in nts]
    fig, ax = plt.subplots(figsize=(11, 7))
    x = range(len(nts))
    ax.plot(x, rr_ttft, "s-", lw=3, ms=12, color="#ff7f0e", label="Round-robin")
    ax.plot(x, aff_ttft, "o-", lw=3, ms=12, color="#1f77b4", label="Affinity (tenant->replica)")
    ax.set_xticks(list(x)); ax.set_xticklabels([f"{n} tenants" for n in nts])
    ax.set_ylabel("TTFT p50 (ms) @ conc 256")
    ax.set_title("Affinity routing cuts cold-swap latency\n(gain largest at low tenant counts: -40% -> -21%)")
    ax.legend(loc="upper left")
    for xi, (r, a) in enumerate(zip(rr_ttft, aff_ttft)):
        ax.annotate(f"-{round((1-a/r)*100)}%", xy=(xi, a), xytext=(xi+0.06, a+10),
                    fontsize=16, color="#1f77b4", fontweight="bold")
    ax.set_ylim(220, 520)
    fig.savefig(os.path.join(OUT, "fig7_tenant_scale_routing.png"))
    plt.close(fig)


# ---- fig8: prompt-size — self-host goodput vs Bedrock (S=512 vs 2048) ----
def fig8():
    b0_512 = load("B0-sysprompt"); b0_2048 = load("B0-2048")
    fig, ax = plt.subplots(figsize=(11, 7))
    ax.plot(col(b0_512, "concurrency"), col(b0_512, "goodput_req_s"), "o-", lw=3, ms=10,
            color="#1f77b4", label="self-host, 512-tok prompt")
    ax.plot(col(b0_2048, "concurrency"), col(b0_2048, "goodput_req_s"), "s-", lw=3, ms=10,
            color="#17becf", label="self-host, 2048-tok prompt")
    # break-even lines (flat) for each prompt size
    for S, c, lab in [(512, "#d62728", "Bedrock break-even S=512 (263)"),
                      (2048, "#9467bd", "Bedrock break-even S=2048 (83)")]:
        be = C_CB / (((S + 10) * P_IN + 64 * P_OUT) / 1e6 * 3600)
        ax.axhline(be, ls="--", lw=2, color=c, label=lab)
    ax.set_xscale("log", base=2)
    ax.set_xlabel("Concurrency"); ax.set_ylabel("Goodput (req/s)")
    ax.set_title("Longer tenant prompt -> self-host wins easier\n(break-even drops as Bedrock bills more input)")
    ax.legend(loc="upper left", fontsize=14)
    fig.savefig(os.path.join(OUT, "fig8_prompt_size.png"))
    plt.close(fig)


# ---- fig9: cost vs monthly tokens, by SaaS tier (replaces the cost_tier table) ----
def fig9():
    import numpy as np
    import matplotlib.patches as mpatches
    # Bedrock: pay-per-token straight line. Blended $/token for the S=512,64out mix.
    S, U, O = 512, 10, 64
    tok_per_req = S + U + O
    bedrock_per_req = ((S + U) * P_IN + O * P_OUT) / 1e6          # $/request
    bedrock_per_tok = bedrock_per_req / tok_per_req               # $/token
    # self-host: fixed monthly cost of one p6-b300 node
    node_month = C_CB * 730                                       # $/month
    be_tok = node_month / bedrock_per_tok                         # break-even monthly tokens
    cap_node = be_tok * 1.5                                       # one node serves ~1.5x break-even before saturating

    # design palette
    INK, SUB, GRID = "#1A2027", "#5A6B7B", "#D8DEE4"
    TEAL, WARN, BG = "#2D6E6E", "#B0563A", "#FBFCFD"
    BEDC = "#5A6B7B"

    fig, ax = plt.subplots(figsize=(12.5, 7.2))
    fig.patch.set_facecolor("white"); ax.set_facecolor(BG)

    xmax = be_tok * 2.0
    x = np.linspace(0, xmax, 400)

    # tier band x-ranges (monthly tokens): Free/Pro small, Enterprise large, Confidential overlaps high
    fp_cap = be_tok * 0.10          # Free/Pro credit cap (low)
    ent_cap = be_tok * 0.85         # Enterprise Bedrock credit cap (strict)
    ax.axvspan(0, fp_cap, color="#EAF1F1", alpha=0.5, zorder=0)
    ax.axvspan(fp_cap, be_tok, color="#F2F4F6", alpha=0.6, zorder=0)
    ax.axvspan(be_tok, xmax, color="#E3EEEC", alpha=0.6, zorder=0)

    # Bedrock pay-per-token line
    ax.plot(x, bedrock_per_tok * x, "-", lw=3.2, color=BEDC, label="Bedrock (pay-per-token)", zorder=5)
    # self-host fixed cost (one node), only meaningful once you commit the node
    ax.hlines(node_month, 0, xmax, ls="--", lw=3, color=TEAL,
              label="Self-host GPU (fixed / node)", zorder=5)

    # break-even marker
    ax.plot([be_tok], [node_month], "o", ms=16, color=TEAL, zorder=7,
            markeredgecolor="white", markeredgewidth=2)
    ax.annotate("break-even\n~692M req/mo (263 req/s)",
                xy=(be_tok, node_month), xytext=(be_tok * 1.02, node_month * 1.55),
                fontsize=15, color=TEAL, fontweight="bold",
                arrowprops=dict(arrowstyle="->", color=TEAL, lw=2))

    ymax = node_month * 3.0
    ax.set_ylim(0, ymax); ax.set_xlim(0, xmax)

    # Free/Pro credit cap (horizontal hard limit on Bedrock spend, low)
    fp_cap_cost = bedrock_per_tok * fp_cap
    ax.plot([0, fp_cap], [fp_cap_cost, fp_cap_cost], ":", lw=2.4, color=WARN, zorder=6)
    ax.plot([fp_cap, fp_cap], [0, fp_cap_cost], ":", lw=2.4, color=WARN, zorder=6)
    ax.annotate("Free/Pro: low credit cap;\nspill to spare GPU when idle",
                xy=(fp_cap, fp_cap_cost), xytext=(fp_cap * 0.6, ymax * 0.42),
                fontsize=13, color=WARN, ha="left",
                bbox=dict(boxstyle="round,pad=0.3", fc="white", ec=WARN, lw=1, alpha=0.95),
                arrowprops=dict(arrowstyle="->", color=WARN, lw=1.6))

    # Enterprise credit cap (strict) + GPU fixed alternative — placed in open space, boxed
    ent_cap_cost = bedrock_per_tok * ent_cap
    ax.plot([ent_cap, ent_cap], [0, ent_cap_cost], ":", lw=2.4, color=WARN, zorder=6)
    ax.annotate("Enterprise: Bedrock credit is strict\n-> run OSS on the fixed-cost GPU pool",
                xy=(ent_cap, node_month), xytext=(fp_cap * 1.05, ymax * 0.74),
                fontsize=13, color=INK, ha="left",
                bbox=dict(boxstyle="round,pad=0.3", fc="white", ec=SUB, lw=1, alpha=0.95),
                arrowprops=dict(arrowstyle="->", color=SUB, lw=1.6))

    # tier labels along the x axis (just above axis)
    for xc, txt, col in [(fp_cap * 0.5, "Free / Pro", TEAL),
                         ((fp_cap + be_tok) / 2, "Enterprise", INK),
                         ((be_tok + xmax) / 2, "Confidential", WARN)]:
        ax.text(xc, ymax * 0.035, txt, ha="center", va="bottom", fontsize=15,
                fontweight="bold", color=col)
    # Confidential note — darker, larger, boxed for contrast
    ax.text((be_tok + xmax) / 2, ymax * 0.115,
            "either path OK if access control\nis enforced (constraints vary)",
            ha="center", va="bottom", fontsize=12.5, color=WARN,
            bbox=dict(boxstyle="round,pad=0.3", fc="white", ec=WARN, lw=1, alpha=0.9))

    # shade region where self-host is cheaper (above break-even tokens, below the bedrock line)
    ax.fill_between(x, node_month, bedrock_per_tok * x,
                    where=(x >= be_tok), color=TEAL, alpha=0.10, zorder=1)
    ax.text(be_tok * 1.5, node_month * 1.62, "self-host cheaper",
            ha="center", fontsize=14, color=TEAL, fontweight="bold")

    ax.set_xlabel("Monthly tokens served  ->")
    ax.set_ylabel("Monthly cost ($)")
    ax.set_title("Cost vs token volume, by SaaS tier\n(Bedrock scales with usage; self-host GPU is a fixed cost)")
    # format axes ticks compactly
    ax.set_yticks([0, node_month, node_month * 2, node_month * 3])
    ax.set_yticklabels(["0", "$68k\n(1 node)", "$137k", "$205k"])
    ax.set_xticks([0, fp_cap, be_tok, xmax])
    ax.set_xticklabels(["0", "low", "break-even", "high"])
    ax.legend(loc="upper center", fontsize=14, framealpha=0.95)
    ax.grid(True, alpha=0.25)
    fig.savefig(os.path.join(OUT, "fig9_cost_tier.png"))
    plt.close(fig)


if __name__ == "__main__":
    fig1(); fig2(); fig3(); fig4(); fig5(); fig6(); fig7(); fig8(); fig9()
    print("[OK] figures generated in", OUT)
    for f in sorted(os.listdir(OUT)):
        print("  ", f)
