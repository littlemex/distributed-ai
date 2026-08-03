#!/usr/bin/env python3
"""Pool the position-profile slopes across seeds and report a seed-level interval.

WHY THIS EXISTS. The per-run analysis reports a cluster bootstrap CI built by resampling
sequences within one run. That interval is real but answers a narrower question than it
appears to: it captures "if I drew a different sample of sequences from this run", not "if
I ran this again". Those differ, because the rollout content itself changes with the seed.

The consequence was concrete. On one seed the fp8_e4m3 slope was +6.31e-07 with a CI of
[+9.88e-08, +1.18e-06] -- an interval excluding zero, which read as a real effect. A second
seed gave -2.31e-08. The first interval did not contain the second estimate, so it was
understating the uncertainty by construction, and the conclusion drawn from it had to be
withdrawn.

So the quantity to report is the spread ACROSS seeds. With k seeds per arm this script
gives the mean slope, the seed-level standard error, and a t-interval on k-1 degrees of
freedom. It also reports how many seeds individually "detected" an effect, because the
gap between that count and the pooled verdict is exactly the trap: several runs can each
look significant while disagreeing with each other about the sign.

Usage:
  python3 pool_seeds.py --arm bf16 <dir> <dir> ... [--arm e4m3 <dir> ...] [--boot 400]
Each <dir> is a mis_dump output directory for one run of that arm.
"""

import argparse
import math
import sys

import numpy as np

from analyze_position_profile import load, token_slope


def arm_slope(dump_dir, min_len=None):
    """Absolute-position slope of |r| for one run. Returns (slope, n_seq, min_len)."""
    seqs, files, n_dup, n_bad = load(dump_dir)
    if not seqs:
        return None, 0, 0, n_bad
    lens = sorted(s["response_len"] for s in seqs)
    ml = min_len or lens[len(lens) // 2]
    kept = [s for s in seqs if s["response_len"] >= ml]
    slope, _ = token_slope(kept, ml)
    return slope, len(kept), ml, n_bad


def t_crit(df):
    """Two-sided 95% t critical value. Table lookup: no scipy in this image."""
    table = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447,
             7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228, 12: 2.179, 15: 2.131,
             20: 2.086, 30: 2.042}
    if df in table:
        return table[df]
    keys = sorted(table)
    for k in keys:
        if df < k:
            return table[k]
    return 1.96


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", action="append", nargs="+", metavar=("NAME", "DIR"),
                    required=True, help="arm name followed by one or more dump dirs")
    ap.add_argument("--min-len", type=int, default=0,
                    help="force a common min_len across all arms (default: per-run median)")
    a = ap.parse_args()

    print(f"{'arm':<10} {'seeds':>6} {'mean slope':>13} {'seed SE':>12} "
          f"{'95% t-interval':>28} {'verdict':>12}")
    print("-" * 88)

    detail = []
    for spec in a.arm:
        name, dirs = spec[0], spec[1:]
        slopes = []
        for d in dirs:
            s, n, ml, nbad = arm_slope(d, a.min_len or None)
            if nbad:
                print(f"  WARNING {d}: {nbad} unreadable npz file(s)", file=sys.stderr)
            if s is None:
                print(f"  WARNING {d}: no usable data", file=sys.stderr)
                continue
            slopes.append(s)
            detail.append((name, d.rstrip("/").split("/")[-1], s, n, ml))
        k = len(slopes)
        if k == 0:
            print(f"{name:<10} {0:>6}  no data")
            continue
        m = float(np.mean(slopes))
        if k == 1:
            print(f"{name:<10} {k:>6} {m:>13.3e} {'n/a':>12} "
                  f"{'n/a (single seed)':>28} {'unknown':>12}")
            continue
        sd = float(np.std(slopes, ddof=1))
        se = sd / math.sqrt(k)
        half = t_crit(k - 1) * se
        lo, hi = m - half, m + half
        verdict = "accumulating" if lo > 0 else ("decreasing" if hi < 0 else "flat")
        print(f"{name:<10} {k:>6} {m:>13.3e} {se:>12.3e} "
              f"{'[' + format(lo, '.3e') + ', ' + format(hi, '.3e') + ']':>28} {verdict:>12}")

    print()
    print("per-run slopes:")
    print(f"  {'arm':<10} {'run':<22} {'slope':>13} {'n_seq':>7} {'min_len':>8}")
    for name, run, s, n, ml in detail:
        print(f"  {name:<10} {run:<22} {s:>13.3e} {n:>7d} {ml:>8d}")

    # The point of the exercise: how many runs individually looked like an effect, versus
    # what the pooled interval says. A large gap means the per-run intervals are too narrow.
    print()
    by_arm = {}
    for name, run, s, n, ml in detail:
        by_arm.setdefault(name, []).append(s)
    for name, ss in by_arm.items():
        if len(ss) < 2:
            continue
        pos = sum(1 for x in ss if x > 0)
        neg = len(ss) - pos
        print(f"  {name}: {pos} run(s) positive, {neg} negative "
              f"-> {'sign is not consistent across seeds' if pos and neg else 'sign is consistent'}")
    print()
    print("A per-run bootstrap CI resamples sequences inside one run; it does not see the")
    print("rollout content change with the seed. Where the sign is inconsistent above, any")
    print("single-run interval that excluded zero was understating the uncertainty.")


if __name__ == "__main__":
    main()
