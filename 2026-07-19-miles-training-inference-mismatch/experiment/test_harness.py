#!/usr/bin/env python3
"""Regression tests for the fabrication-prevention guarantees.

Each test corresponds to a defect that was actually found in review and fixed. The point
is not coverage for its own sake: every one of these is a path by which a wrong number
once could have reached a document, so a failure here means that path is open again.

Run:  python3 test_harness.py
Needs numpy. Does NOT need a cluster, tensorboard, or the miles image -- the TensorBoard
readers are exercised through injected dicts so this stays runnable anywhere.
"""

import math
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import analyze_position_profile as app
import pool_seeds
import verify_results as vr

FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print(f"  PASS  {name}")
    else:
        print(f"  FAIL  {name}  {detail}")
        FAILURES.append(name)


# --------------------------------------------------------------------------------------
# verify_results.py
# --------------------------------------------------------------------------------------

def test_nonfinite_never_verified():
    """inf == inf is True, so a plain equality test stamped VERIFIED on a diverged run."""
    inf, nan = float("inf"), float("nan")
    check("agree(inf, inf) is False", vr.agree(inf, inf) is False)
    check("agree(nan, nan) is False", vr.agree(nan, nan) is False)
    check("agree(1.0, 1.0) is True", vr.agree(1.0, 1.0) is True)
    check("agree tolerates float32 rounding",
          vr.agree(0.000632, 0.00063200001) is True)

    m = vr.verify_cell({"train/grad_norm": inf}, {"grad_norm": "inf"})
    check("inf in both sources -> NONFINITE",
          m["grad_norm"]["verdict"] == "NONFINITE", m["grad_norm"]["verdict"])


def test_sanity_screen_cannot_be_skipped_silently():
    """A run recording none of the screening tags used to 'pass' with zero screens run."""
    ok, fails, notes, unscreened = vr.sanity_check({"train/mis_kl": 0.001})
    check("no screening tags -> unscreened is reported",
          len(unscreened) == 3, f"unscreened={unscreened}")

    # nan satisfied every comparison: nan > thr is False AND nan <= thr is False.
    nan = float("nan")
    ok, fails, notes, unscreened = vr.sanity_check({
        "@first:rollout/repetition_frac": nan,
        "@first:train/mis_ppl_ratio": nan,
        "@first:rollout/raw_reward": nan,
    })
    check("nan screening values -> unscreened, not pass",
          len(unscreened) == 3 and not fails, f"unscreened={unscreened} fails={fails}")

    # A genuinely healthy run must still pass cleanly, or the fix is useless.
    ok, fails, notes, unscreened = vr.sanity_check({
        "@first:rollout/repetition_frac": 0.0, "rollout/repetition_frac": 0.0,
        "@first:train/mis_ppl_ratio": 1.01, "train/mis_ppl_ratio": 1.01,
        "@first:rollout/raw_reward": 0.52, "rollout/raw_reward": 0.50,
        "@n:rollout/raw_reward": 3,
    })
    check("healthy run passes with nothing unscreened",
          ok and not fails and not unscreened, f"ok={ok} fails={fails} un={unscreened}")

    # The 30B failure mode must still be caught.
    ok, fails, notes, unscreened = vr.sanity_check({
        "@first:rollout/repetition_frac": 0.633, "rollout/repetition_frac": 0.633,
        "@first:train/mis_ppl_ratio": 1.78, "train/mis_ppl_ratio": 1.78,
        "@first:rollout/raw_reward": 0.0, "rollout/raw_reward": 0.0,
    })
    check("30B repetition-loop run still fails the screen",
          not ok and len(fails) == 3, f"fails={fails}")

    # A collapse arm is healthy at step 0 and bad at the end: that is the result, not a
    # fault. This distinction is the reason the screen reads step 0.
    ok, fails, notes, unscreened = vr.sanity_check({
        "@first:rollout/repetition_frac": 0.0, "rollout/repetition_frac": 0.27,
        "@first:train/mis_ppl_ratio": 1.02, "train/mis_ppl_ratio": 1.4,
        "@first:rollout/raw_reward": 0.50, "rollout/raw_reward": 0.03,
        "@n:rollout/repetition_frac": 30, "@n:rollout/raw_reward": 30,
    })
    check("collapse arm passes step-0 screen and is noted as a trajectory",
          ok and not fails and len(notes) >= 1, f"ok={ok} notes={notes}")


def test_partial_verdict_demotes():
    """reward VERIFIED + mis_kl MISSING used to print a green VERIFIED for the cell."""
    metrics = vr.verify_cell({"rollout/raw_reward": 0.5}, {"reward": "0.5"})
    core = ("mis_kl", "reward")
    core_bad = sorted({metrics[c]["verdict"] for c in core
                       if metrics.get(c, {}).get("verdict") not in ("VERIFIED", "TB_ONLY")})
    check("mis_kl absent is detected as a core failure",
          core_bad == ["MISSING"], f"core_bad={core_bad}")
    check("reward alone is VERIFIED", metrics["reward"]["verdict"] == "VERIFIED")


# --------------------------------------------------------------------------------------
# analyze_position_profile.py
# --------------------------------------------------------------------------------------

def _write_dump(path, n_seq=4, length=64, run="0c000000", tag="t", rank=0, call=0,
                poison=None):
    """Write one npz shaped like mis_dump.py's output."""
    d = {"n_seq": np.array([n_seq]),
         "total_lengths": np.array([length + 10] * n_seq),
         "response_lengths": np.array([length] * n_seq)}
    rng = np.random.default_rng(0)
    for i in range(n_seq):
        tr = rng.normal(0, 1e-3, length).astype(np.float32)
        ro = rng.normal(0, 1e-3, length).astype(np.float32)
        if poison is not None and i == 0:
            tr = tr.copy()
            tr[length // 2] = poison
        d[f"train_{i}"] = tr
        d[f"rollout_{i}"] = ro
        d[f"mask_{i}"] = np.ones(length, dtype=np.int8)
    os.makedirs(path, exist_ok=True)
    np.savez(os.path.join(path, f"{tag}_{run}_rank{rank}_call{call}.npz"), **d)


def test_run_id_guard_catches_every_id_shape():
    """The old regex only matched digits or lowercase hex, so other ids slipped through."""
    for a_id, b_id, label in [
        ("0c000000", "15000000", "numeric"),
        ("raysubmit1", "raysubmit2", "ray submission id"),
        ("0A1B2C3D", "0E1F2A3B", "uppercase hex"),
        ("try1", "try2", "hand-set label"),
        ("0a", "0b", "short hex"),
    ]:
        d = tempfile.mkdtemp()
        try:
            _write_dump(d, run=a_id, call=0)
            _write_dump(d, run=b_id, call=1)
            raised = False
            try:
                app.load(d)
            except SystemExit:
                raised = True
            check(f"two runs are fatal ({label})", raised)
        finally:
            shutil.rmtree(d, ignore_errors=True)


def test_unparseable_file_is_fatal():
    """A hand-copied file used to be loaded without ever entering the run tally."""
    d = tempfile.mkdtemp()
    try:
        _write_dump(d, run="0c000000")
        np.savez(os.path.join(d, "extra.npz"), n_seq=np.array([0]))
        raised = False
        try:
            app.load(d)
        except SystemExit:
            raised = True
        check("a non-mis_dump .npz in the directory is fatal", raised)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_single_run_still_loads_and_run_id_selects():
    d = tempfile.mkdtemp()
    try:
        _write_dump(d, run="0c000000", call=0)
        seqs, files, n_dup, n_bad, n_nf = app.load(d)
        check("clean single-run directory loads", len(seqs) == 4 and n_bad == 0,
              f"n={len(seqs)}")
        check("no spurious duplicates on distinct data", n_dup == 0, f"n_dup={n_dup}")

        _write_dump(d, run="15000000", call=1)
        seqs, files, n_dup, n_bad, n_nf = app.load(d, run_id="0c000000")
        check("--run-id recovers one run from a mixed directory", len(seqs) == 4,
              f"n={len(seqs)}")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_nonfinite_tokens_do_not_become_a_flat_verdict():
    """nan anywhere made every bootstrap replicate nan; nan fails lo>0 AND hi<0, which
    landed on 'flat: no accumulation detected' -- a confident negative from junk."""
    d = tempfile.mkdtemp()
    try:
        _write_dump(d, run="0c000000", poison=float("-inf"))
        seqs, files, n_dup, n_bad, n_nf = app.load(d)
        check("non-finite tokens are dropped and counted", n_nf == 1, f"n_nonfinite={n_nf}")
        for s in seqs:
            if not np.isfinite(s["r"]).all():
                check("no non-finite r survives load", False)
                break
        else:
            check("no non-finite r survives load", True)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # And if an interval still comes out non-finite, the caller must get None.
    class AllNaN:
        """A seq set whose slope is nan, to drive slope_with_ci's guard."""

    seqs = [{"r": np.array([float("nan")] * 64), "idx": np.arange(64),
             "prompt_len": 10, "response_len": 64} for _ in range(8)]
    rng = np.random.default_rng(0)
    b, signed, lo, hi, n = app.slope_with_ci(seqs, 64, 50, rng)
    check("a non-finite bootstrap interval is returned as None",
          lo is None and hi is None, f"lo={lo} hi={hi}")


def test_alpha_decomposition_matches_its_documented_algebra():
    """alpha_within must not manufacture accumulation from i.i.d. input, and must not
    claim to remove a per-sequence linear trend (it removes only a constant offset)."""
    rng = np.random.default_rng(1)
    L = 512

    def mk(fn):
        return [{"r": fn(rng, L), "idx": np.arange(L), "prompt_len": 0,
                 "response_len": L} for _ in range(64)]

    iid = mk(lambda g, n: g.normal(0, 1e-3, n))
    _, a_raw, a_in = app.cumsum_variance_scaling(iid, L)
    check("i.i.d. input -> alpha_within near 1",
          a_in is not None and 0.8 <= a_in <= 1.2, f"alpha_within={a_in}")

    # Per-sequence CONSTANT offset: inflates alpha_raw, must not inflate alpha_within.
    def const_bias(g, n):
        return g.normal(0, 1e-3, n) + g.normal(0, 5e-3)
    biased = mk(const_bias)
    _, a_raw, a_in = app.cumsum_variance_scaling(biased, L)
    check("constant per-sequence bias inflates alpha_raw",
          a_raw is not None and a_raw > 1.5, f"alpha_raw={a_raw}")
    check("constant per-sequence bias leaves alpha_within near 1",
          a_in is not None and 0.8 <= a_in <= 1.25, f"alpha_within={a_in}")

    # Pure per-sequence LINEAR trend, no noise: the code comment says half of it SURVIVES
    # pair differencing, so alpha_within must go to ~2. This is the claim that was once
    # documented backwards.
    def pure_trend(g, n):
        return g.normal(0, 1e-5) * np.arange(n)
    trend = mk(pure_trend)
    _, a_raw, a_in = app.cumsum_variance_scaling(trend, L)
    check("pure linear trend -> alpha_within near 2 (not removed)",
          a_in is not None and a_in > 1.7, f"alpha_within={a_in}")


# --------------------------------------------------------------------------------------
# pool_seeds.py
# --------------------------------------------------------------------------------------

def test_t_crit_is_conservative():
    """Rounding up returned a value BELOW the true one at every off-table df, narrowing
    the interval -- the direction that manufactures significance."""
    true = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365,
            8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145,
            15: 2.131, 16: 2.120, 17: 2.110, 18: 2.101, 19: 2.093, 20: 2.086, 21: 2.080,
            25: 2.060, 26: 2.056, 30: 2.042, 31: 2.040, 40: 2.021, 45: 2.014, 60: 2.000,
            70: 1.994, 120: 1.980, 200: 1.972, 1000: 1.962}
    bad = [(df, pool_seeds.t_crit(df), t) for df, t in true.items()
           if pool_seeds.t_crit(df) < t - 1e-9]
    check("t_crit >= true value for every tested df", not bad, f"anti-conservative: {bad}")
    check("k=2 (df=1) uses 12.706", pool_seeds.t_crit(1) == 12.706)

    raised = False
    try:
        pool_seeds.t_crit(0)
    except ValueError:
        raised = True
    check("df<1 is rejected rather than silently wrong", raised)


# --------------------------------------------------------------------------------------
# gen_cells.py
# --------------------------------------------------------------------------------------

def test_generated_cells_source_the_frozen_base():
    """Freezing a copy while the cells sourced the original made the frozen file an audit
    trail of something nobody read."""
    here = os.path.dirname(os.path.abspath(__file__))
    tmp = tempfile.mkdtemp()
    try:
        base = os.path.join(tmp, "env_common")
        with open(base, "w") as f:
            f.write('export MODEL_LOCAL="/fsx/models/X"\n')
        spec = os.path.join(tmp, "spec.json")
        with open(spec, "w") as f:
            f.write('{"base_path": "%s", "prefix": "env_", "tag_prefix": "t_",'
                    ' "tensorboard_root": "/fsx/tb",'
                    ' "cells": [{"name": "c1", "vars": {"NUM_ROLLOUT": 1}}]}' % base)
        out = os.path.join(tmp, "out")
        r = subprocess.run([sys.executable, os.path.join(here, "lib", "gen_cells.py"),
                            spec, "--outdir", out],
                           capture_output=True, text=True)
        check("gen_cells succeeds", r.returncode == 0, r.stderr)
        frozen = [f for f in os.listdir(out) if f.startswith("base.")]
        check("a frozen base copy is written", len(frozen) == 1, f"{frozen}")
        cell = open(os.path.join(out, "env_c1")).read()
        check("the cell sources the frozen copy, not the original",
              frozen and frozen[0] in cell and f"source {base}\n" not in cell,
              cell.splitlines()[:6])

        # Editing the original after generation must not change what the cell reads.
        with open(base, "w") as f:
            f.write('export MODEL_LOCAL="/fsx/models/DIFFERENT"\n')
        src = os.path.join(out, frozen[0])
        check("the frozen copy is unaffected by a later edit to the base",
              "/fsx/models/X" in open(src).read())

        # An unreadable base must refuse rather than emit unreproducible cells.
        spec2 = os.path.join(tmp, "spec2.json")
        with open(spec2, "w") as f:
            f.write('{"base_path": "%s/nope", "cells": [{"name": "c1"}]}' % tmp)
        r = subprocess.run([sys.executable, os.path.join(here, "lib", "gen_cells.py"),
                            spec2, "--outdir", os.path.join(tmp, "out2")],
                           capture_output=True, text=True)
        check("a missing base_path is refused", r.returncode != 0, r.stdout + r.stderr)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    tests = [
        ("verify_results: non-finite values are never VERIFIED", test_nonfinite_never_verified),
        ("verify_results: the sanity screen cannot be skipped silently",
         test_sanity_screen_cannot_be_skipped_silently),
        ("verify_results: a missing core metric demotes the cell", test_partial_verdict_demotes),
        ("position profile: the run-id guard catches every id shape",
         test_run_id_guard_catches_every_id_shape),
        ("position profile: an unparseable file is fatal", test_unparseable_file_is_fatal),
        ("position profile: clean loads and --run-id still work",
         test_single_run_still_loads_and_run_id_selects),
        ("position profile: nan does not become a 'flat' verdict",
         test_nonfinite_tokens_do_not_become_a_flat_verdict),
        ("position profile: the alpha decomposition matches its documented algebra",
         test_alpha_decomposition_matches_its_documented_algebra),
        ("pool_seeds: t_crit errs on the conservative side", test_t_crit_is_conservative),
        ("gen_cells: generated cells source the frozen base",
         test_generated_cells_source_the_frozen_base),
    ]
    for name, fn in tests:
        print(f"\n{name}")
        fn()
    print("\n" + "=" * 70)
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S): {FAILURES}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
