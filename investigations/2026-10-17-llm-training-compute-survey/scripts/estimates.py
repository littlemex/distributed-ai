"""Reproduce the model-based estimates in the article: the H200 -> B200 replacement, KV seats, RL transfer coefficient and GPU-hours."""
import math

# Peak values: NVIDIA datasheets (bf16 dense, HBM bandwidth) and AWS product pages (HBM per instance)
PEAK = {"H200": 0.9895e15, "B200": 2.25e15}
BW = {"H100": 3.35, "H200": 4.8, "B200": 7.7, "B300": 7.7}          # TB/s per GPU
HBM_NODE = {"p5en": 1128, "p6-b200": 1432, "p6-b300": 2144}         # GB per 8-GPU instance
ETA = 0.95

r_peak = PEAK["B200"] / PEAK["H200"]
r_bw = BW["B200"] / BW["H200"]
print(f"r_peak {r_peak:.3f}  r_bw {r_bw:.3f}  ridge H200 {989.5 / 4.8:.0f}  B200 {2250 / 7.7:.0f} FLOP/byte")


def replace(f, r, eta=ETA, gpus=64):
    s = eta / sum(a / b for a, b in zip(f, r))
    need = math.ceil(gpus / s)
    return s / r_peak, need, math.ceil(need / 8)


print("\n# 8 x p5en (64 GPUs) -> p6-b200: shares (compute, HBM, inter-node, wait)")
for f in ([1.0], [0.8, 0.1, 0.05, 0.05], [0.6, 0.25, 0.10, 0.05], [0.5, 0.2, 0.25, 0.05]):
    r = [r_peak, r_bw, 1.0, 1.0][: len(f)]
    k, g, n = replace(f, r)
    print(f"{f}: k={k:.2f} GPUs={g} instances={n}")
print("eta=0.8, row 3:", replace([0.6, 0.25, 0.10, 0.05], [r_peak, r_bw, 1.0, 1.0], eta=0.8)[1:])
print(f"HBM 8 x p5en {8 * HBM_NODE['p5en']} GB, 4 x p6-b200 {4 * HBM_NODE['p6-b200']} GB")

print("\n# KV seats for GLM-4.5-Air (46 layers, 8 KV heads, head_dim 128), 32K tokens, 90% of HBM, weights spread over 8 GPUs")
kv_bf16 = 2 * 46 * 8 * 128 * 2 * 32768 / 1e9
for node, hbm in HBM_NODE.items():
    bf16 = int((hbm * 0.9 - 212) // kv_bf16)
    fp8 = int((hbm * 0.9 - 106) // (kv_bf16 / 2))
    print(f"{node}: KV space {hbm * 0.9 - 212:.0f} GB, bf16 seats {bf16}, fp8 seats {fp8}")

print("\n# RL step: shares (rollout bulk, tail, logprob+train, weight sync, reward/env)")
for lab, r0 in (("bandwidth", r_bw), ("seat", 174 / 130)):
    k, g, n = replace([0.45, 0.25, 0.20, 0.05, 0.05], [r0, r_bw, 2.0, 1.5, 1.0])
    print(f"rollout bulk at {lab} ratio: k={k:.2f} GPUs={g} instances={n}")

print("\n# GLM-4.5-Air-shaped pre-training: 6 x 12B x 23T on B200, A = 1")
C = 6 * 12e9 * 23e12
for mfu in (0.30, 0.35, 0.40):
    gh = C / (PEAK["B200"] * mfu) / 3600
    print(f"MFU {mfu:.0%}: {gh / 1e3:.0f}K GPU-hours, {gh / 512 / 24:.1f} days on 512 GPUs")
print(f"1 point of MFU at 35%: +{(0.35 / 0.34 - 1) * 100:.1f}% GPU-hours")
