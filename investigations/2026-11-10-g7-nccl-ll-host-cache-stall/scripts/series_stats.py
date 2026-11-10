import sys
t = [float(x) for x in open(sys.argv[1])]; thr = float(sys.argv[2])
n = len(t); s = sorted(t)
slow = [x > thr for x in t]
runs = []; cur = slow[0]; L = 0
for b in slow:
    if b == cur: L += 1
    else: runs.append((cur, L)); cur = b; L = 1
runs.append((cur, L))
sr = [L for b, L in runs if b]; fr = [L for b, L in runs if not b]
print(f"n={n} p10={s[n//10]:.0f} p50={s[n//2]:.0f} p90={s[n*9//10]:.0f} max={s[-1]:.0f} us | slow(>{thr:.0f}us)={sum(slow)/n*100:.1f}%")
print(f"  transitions={len(runs)-1} slow_runs={len(sr)} (max len {max(sr) if sr else 0}) fast_runs={len(fr)} (max len {max(fr) if fr else 0})")
bins = [0, 500, 1000, 2000, 5000, 10000, 20000, 40000, 1e9]
print("  hist:", " ".join(f"[{bins[i]:.0f}-{bins[i+1]:.0f}):{sum(bins[i] <= x < bins[i+1] for x in t)}" for i in range(len(bins)-1)))
first = [i for i, b in enumerate(slow) if b]
print(f"  first slow op index={first[0] if first else None}; first 30 ops:", " ".join(f"{x:.0f}" for x in t[:30]))
