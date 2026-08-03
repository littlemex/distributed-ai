"""Position-profile analysis of the train/rollout logprob gap.

The question: is the per-token gap r_t = train_logprob_t - rollout_logprob_t flat in
sequence position, or does it grow? That distinguishes the two readings of the O(T^2)
claim in arXiv:2602.01826 Thm 3.1 -- a flat gap accumulates like T, a growing one like
T^2. Attention is causal, so a profile measured on an 8192-token run is the same
quantity as the first 8192 positions of a longer run.

Hypothesis: bf16 is numerical-path noise and should be flat; fp8 KV should accumulate,
because every token attends to a quantised cache.

Four points of method, each of which changes the answer:

  1. ABSOLUTE position, not relative. The hypothesised mechanism is "error grows with
     the number of quantised KV entries attended to", which is a function of absolute
     position. Relative position (t/n) also mixes sequences of different length into one
     bin, and fp8 changes the generation distribution, so the length distribution itself
     differs between arms. Relative position is reported only as a secondary view.

  2. PROMPT OFFSET. The number of cached entries a response token attends to is
     prompt_len + t, not t. Using t alone lets a difference in prompt-length
     distribution masquerade as a position effect.

  3. LENGTH STRATIFICATION. Even at absolute position, arms are compared only over
     sequences long enough to reach the position in question, so both arms are censored
     the same way.

  4. CLUSTER BOOTSTRAP for the slope CI. Tokens within a sequence are strongly
     correlated, so an ordinary OLS standard error is meaningless here. Resampling whole
     sequences gives an interval that reflects the real unit of independence. A slope
     without an interval cannot distinguish accumulation from noise at small n.

On the variance scaling: Var[cumsum(T)] ~ T^alpha is often read as alpha≈1 => r is
effectively i.i.d. (token-level TIS suffices), alpha≈2 => systematic bias (sequence-level
correction matters). But a per-sequence mean bias mu_j that merely *varies between
sequences* already gives Var ≈ Var(mu_j)*T^2 + sigma^2*T, driving alpha to 2 with no
position dependence at all. So alpha is reported twice: raw, and after centring r within
each sequence. The centred alpha is the position-dependent component; the gap between
them is the between-sequence bias component.

Usage:
  python3 analyze_position_profile.py <dump_dir> [--bins 16] [--label NAME]
                                      [--boot 1000] [--min-len N]
Reads *.npz written by mis_dump.py.
"""

import argparse
import glob
import hashlib
import math
import os
import re
import sys

import numpy as np


def load(dump_dir, run_id=None):
    """Return per-sequence dicts (r masked, prompt_len, response_len) plus a tally.

    Duplicates are dropped by content hash. The dump already restricts itself to TP rank
    0, but a second line of defence is worth having: if the same sequence were counted
    TP times, n would inflate and the sequence-level bootstrap CI would narrow by about
    sqrt(TP), which is exactly the number the accumulation verdict is read off. Files
    that fail to load are counted rather than silently skipped, because "could not read
    the data" and "there was no data" are different findings.
    """
    seqs = []
    seen, n_dup, n_bad = set(), 0, 0
    files = sorted(glob.glob(os.path.join(dump_dir, "*.npz")))
    if run_id:
        files = [f for f in files if f"_{run_id}_rank" in os.path.basename(f)]

    # Refuse a directory holding dumps from more than one run. Filenames carry the run id
    # (<tag>_<run>_rank<r>_call<n>.npz), and re-running a cell into the same MIS_DUMP_DIR
    # leaves both sets side by side. Content hashing does not catch that: the sequences
    # genuinely differ, so every one is kept, n doubles, two different model states are
    # pooled, and the sequence-level bootstrap interval narrows for no reason. Since that
    # interval is what the accumulation verdict is read off, this has to be fatal rather
    # than a warning.
    runs = set()
    for f in files:
        m = re.search(r"_(\d+|[0-9a-f]{8,})_rank\d+_call\d+\.npz$", os.path.basename(f))
        if m:
            runs.add(m.group(1))
    if len(runs) > 1:
        raise SystemExit(
            f"{dump_dir} holds dumps from {len(runs)} runs: {sorted(runs)}\n"
            "Pooling them would inflate n and narrow the interval. Point MIS_DUMP_DIR at a\n"
            "fresh directory per run, or pass --run-id to select one."
        )

    for p in files:
        try:
            z = np.load(p)
        except Exception:
            n_bad += 1
            continue
        n_seq = int(z["n_seq"][0]) if "n_seq" in z else 0
        totals = z["total_lengths"] if "total_lengths" in z else np.zeros(n_seq, int)
        resps = z["response_lengths"] if "response_lengths" in z else np.zeros(n_seq, int)
        for i in range(n_seq):
            k_tr, k_ro, k_m = f"train_{i}", f"rollout_{i}", f"mask_{i}"
            if k_tr not in z or k_ro not in z:
                continue
            tr = np.asarray(z[k_tr], dtype=np.float64)
            ro = np.asarray(z[k_ro], dtype=np.float64)
            n = min(len(tr), len(ro))
            if n == 0:
                continue
            r = tr[:n] - ro[:n]
            if k_m in z:
                m = np.asarray(z[k_m])[:n] > 0
            else:
                m = np.ones(n, dtype=bool)
            if not m.any():
                continue
            h = hashlib.sha1(tr[:n].tobytes() + ro[:n].tobytes()).hexdigest()
            if h in seen:
                n_dup += 1
                continue
            seen.add(h)
            resp_len = int(resps[i]) if i < len(resps) else n
            total_len = int(totals[i]) if i < len(totals) else n
            # Prompt length is what the response's absolute positions are offset by.
            prompt_len = max(0, total_len - resp_len)
            seqs.append({
                "r": r[m],
                "idx": np.nonzero(m)[0],   # index within the response
                "prompt_len": prompt_len,
                "response_len": resp_len,
            })
    return seqs, files, n_dup, n_bad


def _ols_slope(x, y):
    x = np.asarray(x, dtype=np.float64)
    y = np.asarray(y, dtype=np.float64)
    if len(x) < 3:
        return None
    den = ((x - x.mean()) ** 2).sum()
    if den == 0:
        return None
    return float(((x - x.mean()) * (y - y.mean())).sum() / den)


def token_slope(seqs, min_len):
    """OLS slope of |r| against ABSOLUTE position, over tokens.

    Absolute position is prompt_len + response index: that is the number of cached KV
    entries the token attends to, which is the quantity the accumulation hypothesis is
    about. Using the response index alone lets a difference in prompt-length distribution
    between arms appear as a position effect, and fp8 does change the generation
    distribution, so the offset is not optional.

    This works on tokens rather than bin means because binning by absolute position and
    stratifying by length (so every bin holds the same set of sequences) cannot both be
    satisfied; the binned table below is kept for display, and the slope reported comes
    from here.
    """
    xs, ys, ss = [], [], []
    for s in seqs:
        if s["response_len"] < min_len:
            continue
        sel = s["idx"] < min_len
        if not sel.any():
            continue
        xs.append(s["prompt_len"] + s["idx"][sel])
        ys.append(np.abs(s["r"][sel]))
        ss.append(s["r"][sel])
    if not xs:
        return None, None
    x = np.concatenate(xs)
    return _ols_slope(x, np.concatenate(ys)), _ols_slope(x, np.concatenate(ss))


def abs_position_profile(seqs, nbins, min_len):
    """Bin |r| by response-relative index, for display.

    Only sequences reaching min_len are used, and only positions up to min_len, so every
    bin is populated by the same set of sequences. That is what makes the table
    comparable across arms: no bin is an average over a self-selected subset of long
    sequences. The slope quoted in the report comes from token_slope(), which uses
    absolute position including the prompt offset.
    """
    kept = [s for s in seqs if s["response_len"] >= min_len]
    if not kept:
        return [], 0
    edges = np.linspace(0, min_len, nbins + 1)
    sums = np.zeros(nbins)
    abs_sums = np.zeros(nbins)
    counts = np.zeros(nbins, dtype=np.int64)
    for s in kept:
        sel = s["idx"] < min_len
        if not sel.any():
            continue
        idx = s["idx"][sel]
        r = s["r"][sel]
        b = np.clip(np.digitize(idx, edges) - 1, 0, nbins - 1)
        np.add.at(sums, b, r)
        np.add.at(abs_sums, b, np.abs(r))
        np.add.at(counts, b, 1)
    rows = []
    for i in range(nbins):
        c = int(counts[i])
        rows.append({
            "bin": i,
            # Absolute position centre, including the mean prompt offset.
            "resp_pos": float((edges[i] + edges[i + 1]) / 2),
            "n": c,
            "mean_r": float(sums[i] / c) if c else None,
            "mean_abs_r": float(abs_sums[i] / c) if c else None,
        })
    return rows, len(kept)


def slope_with_ci(seqs, min_len, n_boot, rng):
    """Absolute-position slope of |r|, with a sequence-level bootstrap CI."""
    kept = [s for s in seqs if s["response_len"] >= min_len]
    if not kept:
        return None, None, None, None, 0
    point, signed = token_slope(kept, min_len)
    if point is None:
        return None, None, None, None, len(kept)
    boots = []
    for _ in range(n_boot):
        # Resample sequences, not tokens: tokens inside a sequence are strongly
        # correlated, so the sequence is the unit of independence. Resampling tokens
        # would shrink the interval to meaninglessness.
        sample = [kept[i] for i in rng.integers(0, len(kept), len(kept))]
        b, _ = token_slope(sample, min_len)
        if b is not None:
            boots.append(b)
    if len(boots) < 20:
        return point, signed, None, None, len(kept)
    lo, hi = np.percentile(boots, [2.5, 97.5])
    return point, signed, float(lo), float(hi), len(kept)


def cumsum_variance_scaling(seqs, min_len, fracs=(0.125, 0.25, 0.5, 1.0)):
    """Var[cumsum r] vs prefix length, decomposed.

    Var[sum_{t<k} r_t] over sequences mixes two sources:
      - between-sequence bias: each sequence has its own mean mu_j, contributing
        Var(mu_j) * k^2, which drives alpha to 2 with no position dependence at all;
      - within-sequence fluctuation, contributing ~ sigma^2 * k when r is i.i.d.

    So alpha alone cannot support an O(T^2) claim. The decomposition here is explicit:
    var_bias is the pure mu_j * k term, and var_within is the variance of the prefix sum
    after subtracting each sequence's OWN mean times the prefix length. Subtracting the
    full-sequence mean from every element (an earlier version of this function) is wrong:
    on a prefix it removes k*mu_j, which is the right quantity, but the mean must be
    estimated from the whole sequence rather than the prefix or the two terms stop being
    comparable across k. Verified against synthetic data with known structure: a
    per-sequence-bias-only generator gives alpha_raw ~ 2 and alpha_within ~ 1.
    """
    kept = [s for s in seqs if s["response_len"] >= min_len]
    if len(kept) < 2:
        return [], None, None

    # var_within uses the sum of ADJACENT PAIR DIFFERENCES, not a subtracted mean
    # estimate. Estimating mu_j and subtracting it leaves the estimator's own noise
    # behind, and that noise term scales like k^2 -- it lifted alpha_within to ~1.3 on
    # i.i.d. data, i.e. it manufactured a mild "accumulation" out of flat input. Pair
    # differences cancel any locally-constant per-sequence bias exactly, with no
    # estimation noise and no scaling factor:
    #   r i.i.d.                -> Var[D_k] = k*sigma^2       (alpha 1)
    #   sigma_t^2 ~ position    -> Var[D_k] = sum sigma_t^2   (alpha 2)
    #   per-sequence CONSTANT   -> contributes exactly 0
    #   per-sequence LINEAR TREND r_t = b_j*t -> each pair difference is the constant
    #     -b_j, so D_k = -b_j*k/2 and Var(b_j)*k^2/4 SURVIVES, pushing alpha toward 2.
    #
    # That last line corrects an earlier comment here which claimed trends were removed.
    # They are not: differencing kills a constant offset exactly and leaves half of a
    # linear trend. Verified directly -- a pure per-sequence linear trend with no noise
    # gives alpha_within 2.03, and the same trend buried under realistic noise gives 1.04
    # because the noise term dominates at these amplitudes.
    #
    # So alpha_within answers "does the variance grow along a sequence, from either a
    # position-dependent scale or a spread of per-sequence trends", and it does NOT
    # separate those two. What it does exclude is a spread of constant offsets, which is
    # what inflates alpha_raw. Read the pair (alpha_raw, alpha_within) together.
    out = []
    for frac in fracs:
        k = max(2, int(min_len * frac))
        raw, within = [], []
        for s in kept:
            r = s["r"][s["idx"] < k]
            if r.size < 2:
                continue   # skip rather than append 0.0, which would deflate the variance
            raw.append(float(r.sum()))
            n_pair = r.size // 2
            d = r[0:2 * n_pair:2] - r[1:2 * n_pair:2]
            within.append(float(d.sum()))
        if len(raw) < 2:
            continue
        out.append({
            "frac": frac, "k": k, "n_seq": len(raw),
            "mean_cumsum": float(np.mean(raw)),
            "var_raw": float(np.var(raw, ddof=1)),
            "var_within": float(np.var(within, ddof=1)),
        })

    def fit(key):
        pts = [(math.log(o["k"]), math.log(o[key])) for o in out if o[key] > 0]
        if len(pts) < 2:
            return None
        return _ols_slope([p[0] for p in pts], [p[1] for p in pts])

    return out, fit("var_raw"), fit("var_within")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump_dir")
    ap.add_argument("--bins", type=int, default=16)
    ap.add_argument("--label", default="")
    ap.add_argument("--boot", type=int, default=1000)
    ap.add_argument("--min-len", type=int, default=0,
                    help="compare only sequences reaching this response length "
                         "(default: the median, so half the sequences are used)")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--run-id", default="",
                    help="when a dump directory holds several runs, analyse only this one")
    a = ap.parse_args()

    seqs, files, n_dup, n_bad = load(a.dump_dir, a.run_id or None)
    label = a.label or os.path.basename(a.dump_dir.rstrip("/"))
    print(f"label={label}")
    print(f"argv: {' '.join(sys.argv[1:])}")
    print(f"files={len(files)} sequences={len(seqs)} "
          f"duplicates_dropped={n_dup} unreadable_files={n_bad}")
    if n_bad:
        print(f"  WARNING: {n_bad} npz file(s) could not be read -- that is not the "
              "same as there being no data; investigate before reporting.")
    if n_dup:
        print(f"  note: {n_dup} duplicate sequence(s) dropped by content hash "
              "(expected 0 now that the dump is restricted to TP rank 0)")
    if not seqs:
        print("no data")
        return

    lens = sorted(s["response_len"] for s in seqs)
    plens = sorted(s["prompt_len"] for s in seqs)
    print(f"response_len: min={lens[0]} median={lens[len(lens)//2]} max={lens[-1]}")
    print(f"prompt_len:   min={plens[0]} median={plens[len(plens)//2]} max={plens[-1]}")
    min_len = a.min_len or lens[len(lens) // 2]
    print(f"min_len for comparison = {min_len} "
          f"(sequences reaching it: {sum(1 for L in lens if L >= min_len)}/{len(lens)})")

    rows, n_kept = abs_position_profile(seqs, a.bins, min_len)
    print()
    print(f"{'resp_pos':>10} {'n':>9} {'mean_r':>14} {'mean|r|':>14}")
    for r in rows:
        if not r["n"]:
            continue
        print(f"{r['resp_pos']:10.1f} {r['n']:9d} {r['mean_r']:14.6e} {r['mean_abs_r']:14.6e}")

    rng = np.random.default_rng(a.seed)
    b, signed, lo, hi, n_kept = slope_with_ci(seqs, min_len, a.boot, rng)
    print()
    if b is None:
        print("slope: insufficient data")
    else:
        span = b * min_len
        vals = [r["mean_abs_r"] for r in rows if r["mean_abs_r"] is not None]
        mean_abs = float(np.mean(vals)) if vals else 0.0
        print(f"OLS slope of |r| vs ABSOLUTE position (prompt_len + idx), over tokens "
              f"of {n_kept} sequences: {b:.6e} per token")
        if lo is not None:
            print(f"  95% CI (sequence-level bootstrap, n={a.boot}): [{lo:.3e}, {hi:.3e}]")
        if mean_abs > 0:
            print(f"  change across {min_len} tokens: {span:+.3e} "
                  f"({span / mean_abs:+.1%} of mean|r|)")
        else:
            print(f"  change across {min_len} tokens: {span:+.3e}")
        if signed is not None:
            # fp8's systematic error could be a signed drift rather than a growth in
            # magnitude; the verdict stays on |r| but the signed slope aids reading.
            print(f"  signed slope (r, not |r|): {signed:.6e} per token")
        if lo is not None:
            if lo > 0:
                print("  => accumulating: CI excludes zero")
            elif hi < 0:
                print("  => decreasing: CI excludes zero")
            else:
                print("  => flat: CI includes zero (no accumulation detected)")
        print("  reminder: compare the prompt_len distributions printed above between "
              "arms; if they differ materially, the absolute-position comparison is "
              "still offset-correct but the token mix behind each position differs.")

    cs, alpha_raw, alpha_within = cumsum_variance_scaling(seqs, min_len)
    print()
    print("cumulative-sum variance scaling:")
    for o in cs:
        print(f"  k={o['k']:6d} n={o['n_seq']:4d} mean={o['mean_cumsum']:+12.5e} "
              f"var_raw={o['var_raw']:12.5e} var_within={o['var_within']:12.5e}")
    if alpha_raw is not None:
        print(f"  alpha raw    (var ~ T^a): {alpha_raw:.2f}")
    if alpha_within is not None:
        print(f"  alpha within (var ~ T^a): {alpha_within:.2f}   "
              "<- after removing each sequence's own bias")
        print("    within near 1 => r effectively i.i.d. inside a sequence")
        print("    within near 2 => variance grows along a sequence (position-dependent")
    print("                     scale, or a spread of per-sequence trends)")
    if alpha_raw is not None and alpha_within is not None:
        gap = alpha_raw - alpha_within
        if gap > 0.3:
            print("    raw exceeds within => part of the T^2-looking growth is bias "
                  "spread ACROSS sequences rather than growth along one. A "
                  "sequence-level correction is what addresses that part, and alpha_raw "
                  "on its own is not evidence for per-token O(T^2) accumulation.")
        else:
            print("    raw and within agree => the scaling is a within-sequence "
                  "property, not an artefact of between-sequence bias spread.")
    # Deliberately not reported: a point estimate of "what fraction of Var[cumsum] is
    # between-sequence bias". Two estimators were tried (full-sequence mean, and a
    # parity-split mean) and both returned impossible values on synthetic controls --
    # >100% on a growing-|r| generator, ~90% on one built with no bias at all -- because
    # they assume stationarity within a sequence, which is exactly what is under test.
    # The alpha_raw/alpha_within comparison above carries the same information without
    # requiring that assumption.
    print()
    print("note: log-log points share prefixes (cumsum at T and 2T are nested), so the "
          "alpha fit's residuals are not independent; treat alpha as descriptive.")


if __name__ == "__main__":
    main()
