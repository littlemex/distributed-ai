#!/usr/bin/env python3
"""Verify every reported number against primary data, and flag what cannot be verified.

WHY THIS EXISTS. Six cells were once reported with values that no run had produced. The
numbers looked plausible, sat in a well-formatted table, and nothing in the pipeline
objected. What was missing was not care but a mechanical check: a step that takes a claim
and goes and looks.

So this tool does not trust any summary, table or note. For each run it reads the
TensorBoard event file the trainer wrote, and independently the driver's results.tsv, and
compares them. A number is VERIFIED only when two sources that were written by different
code paths agree.

Verdicts:
  VERIFIED     both tb and results.tsv have the value and they agree
  TB_ONLY      only the trainer's event file has it (run predates the driver) -- usable,
               single-source
  DRIVER_ONLY  only results.tsv has it; tb is missing. Suspicious: investigate
  DISAGREE     both have it and they differ. Never publish this
  MISSING      neither source has it. If a document reports a number for this cell, that
               number is fabricated
  NOT_SUCCEEDED  the run exists but its terminal status was not SUCCEEDED

It also runs a sanity screen. A value can be genuine and still be meaningless: the 30B
MoE produced mis_kl 0.309 from real runs whose generation was stuck in repetition loops
(repetition_frac 0.63, reward 0.0, mis_ppl_ratio 1.78). Numbers that fail the screen are
marked UNUSABLE so they cannot be quoted as measurements of what they were meant to
measure.

Usage:
  python3 verify_results.py [--exp-root /fsx/exp] [--tb-root /fsx/tb] [--json out.json]
Run it on the Ray head pod, where /fsx is mounted.
"""

import argparse
import glob
import re
import json
import os
import sys

# results.tsv column name -> tb scalar tag
COL_TO_TAG = {
    "mis_kl": "train/mis_kl",
    "chi2_token": "train/mis_chi2_token",
    "ppo_kl": "train/ppo_kl",
    "abs_diff": "train/train_rollout_logprob_abs_diff",
    "grad_norm": "train/grad_norm",
    "reward": "rollout/raw_reward",
}

# Screens that decide whether a genuine number is meaningful. Thresholds are set from the
# healthy dense runs, where repetition is 0.0, reward 0.42-0.55 and ppl_ratio <= 1.033.
SANITY = [
    ("rollout/repetition_frac", "<=", 0.05,
     "generation is looping; the logprob gap measures repetition, not the intended effect"),
    ("train/mis_ppl_ratio", "<=", 1.5,
     "trainer and rollout evaluate materially different distributions"),
    ("rollout/raw_reward", ">", 0.0,
     "no correct answers at all; responses never reach an answer"),
]

# The screen is applied to step 0, not to the last step, and this distinction decides
# whether a run is broken or is showing the effect it was built to show.
#
# A collapse or TIS-rescue arm is *supposed* to end badly: the amplified runs start at
# repetition 0.0 and reward 0.40-0.55 and walk to repetition 0.27 and reward 0.03 over 30
# steps. Judging them on their final step marks the finding itself as a defect. A broken
# run is different in kind -- the 30B MoE is already looping at step 0, before any
# optimizer step has been taken, so nothing it reports can be about training dynamics.
#
# So: step 0 must be healthy for the run to be measuring anything. What happens afterwards
# is the result, and is reported separately as a trajectory rather than screened.
SANITY_AT_STEP = 0

REL_TOL = 1e-3   # tb writes float32, the driver parses the printed float64 repr


def tb_scalars(tb_dir):
    """Last value of every scalar tag in a TensorBoard run directory."""
    if not glob.glob(os.path.join(tb_dir, "**", "events*"), recursive=True):
        return None
    try:
        from tensorboard.backend.event_processing.event_accumulator import EventAccumulator
        ea = EventAccumulator(tb_dir)
        ea.Reload()
    except Exception as e:
        print(f"  ! could not read {tb_dir}: {type(e).__name__}: {e}", file=sys.stderr)
        return None
    out = {}
    for tag in ea.Tags().get("scalars", []):
        try:
            s = ea.Scalars(tag)
            out[tag] = float(s[-1].value)
            # Keep step 0 and the step count too: the sanity screen judges the start, and
            # a multi-step run's decline is a result rather than a fault.
            out["@first:" + tag] = float(s[0].value)
            out["@n:" + tag] = len(s)
        except Exception:
            pass
    return out


def read_results_tsv(path):
    """Latest attempt per cell from a driver results.tsv."""
    if not os.path.isfile(path):
        return {}
    with open(path) as f:
        lines = [l.rstrip("\n") for l in f if l.strip()]
    if len(lines) < 2:
        return {}
    header = lines[0].split("\t")
    rows = {}
    for line in lines[1:]:
        parts = line.split("\t")
        if len(parts) != len(header):
            continue
        rec = dict(zip(header, parts))
        rows[rec["cell"]] = rec       # later rows win: latest attempt
    return rows


def agree(a, b):
    if a is None or b is None:
        return False
    if a == b:
        return True
    scale = max(abs(a), abs(b), 1e-30)
    return abs(a - b) / scale <= REL_TOL


def verify_cell(tb, row):
    """Per-metric verdicts for one cell."""
    out = {}
    for col, tag in COL_TO_TAG.items():
        tb_v = tb.get(tag) if tb else None
        raw = (row or {}).get(col)
        drv_v = None
        if raw not in (None, "", "-"):
            try:
                drv_v = float(raw)
            except ValueError:
                drv_v = None
        if tb_v is not None and drv_v is not None:
            verdict = "VERIFIED" if agree(tb_v, drv_v) else "DISAGREE"
        elif tb_v is not None:
            verdict = "TB_ONLY"
        elif drv_v is not None:
            verdict = "DRIVER_ONLY"
        else:
            verdict = "MISSING"
        out[col] = {"tb": tb_v, "driver": drv_v, "verdict": verdict}
    return out


def sanity_check(tb):
    """Return (ok, failures, trajectory_notes).

    Screened on step 0 (see SANITY_AT_STEP). Screens with no data are not failures.
    Degradation after step 0 is reported as a note, never as a failure.
    """
    if not tb:
        return True, [], []
    fails, notes = [], []
    for tag, op, thr, why in SANITY:
        v0 = tb.get("@first:" + tag)
        vl = tb.get(tag)
        if v0 is None:
            continue
        bad = (v0 > thr) if op == "<=" else (v0 <= thr)
        if bad:
            fails.append(f"{tag} at step 0 = {v0:.6g} ({op} {thr} expected): {why}")
        elif vl is not None:
            worsened = (vl > thr) if op == "<=" else (vl <= thr)
            n = int(tb.get("@n:" + tag, 1))
            if worsened and n > 1:
                notes.append(f"{tag}: {v0:.6g} at step 0 -> {vl:.6g} by step {n - 1} "
                             "(healthy start, degraded later: a trajectory, not a fault)")
    return (not fails), fails, notes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exp-root", default="/fsx/exp")
    ap.add_argument("--tb-root", default="/fsx/tb")
    ap.add_argument("--json", default="")
    a = ap.parse_args()

    # Every run known to either source. tb dir names are the run tags; the driver groups
    # cells under a batch, so the tb name is <tag_prefix><cell> and has to be discovered.
    tb_runs = sorted(os.path.basename(p) for p in glob.glob(os.path.join(a.tb_root, "*"))
                     if os.path.isdir(p))
    batches = sorted(os.path.basename(p) for p in glob.glob(os.path.join(a.exp_root, "*"))
                     if os.path.isdir(p))

    # Map tb run -> (batch, cell) by suffix match, so a driver row can be paired with the
    # event file the same run wrote.
    pairing = {}
    for b in batches:
        rows = read_results_tsv(os.path.join(a.exp_root, b, "results.tsv"))
        for cell, row in rows.items():
            # The frozen env copy records the TENSORBOARD_DIR that was actually
            # submitted, so prefer that over guessing from names. Name matching stays as
            # a fallback for rows written before envs were frozen.
            tb_run = None
            envf = os.path.join(a.exp_root, b, "env", f"{cell}.env")
            if os.path.isfile(envf):
                for line in open(envf):
                    m = re.search(r'TENSORBOARD_DIR=[\'"]?([^\'"\s]+)', line)
                    if m:
                        tb_run = os.path.basename(m.group(1).rstrip("/"))
                        break
            if tb_run is None:
                hits = [r for r in tb_runs if r == cell or r.endswith("_" + cell)]
                if len(hits) > 1:
                    narrowed = [h for h in hits if h.startswith(b.split("_")[0])]
                    hits = narrowed or hits
                tb_run = hits[0] if hits else None
            pairing[(b, cell)] = (tb_run, row)

    report = []
    for (batch, cell), (tb_run, row) in sorted(pairing.items()):
        tb = tb_scalars(os.path.join(a.tb_root, tb_run)) if tb_run else None
        status = row.get("status", "?")
        metrics = verify_cell(tb, row)
        ok, fails, notes = sanity_check(tb)
        verdicts = {m["verdict"] for m in metrics.values()}
        if status != "SUCCEEDED":
            overall = "NOT_SUCCEEDED"
        elif "DISAGREE" in verdicts:
            overall = "DISAGREE"
        elif verdicts == {"MISSING"}:
            overall = "MISSING"
        elif "DRIVER_ONLY" in verdicts:
            overall = "DRIVER_ONLY"
        elif "VERIFIED" in verdicts:
            overall = "VERIFIED" if ok else "VERIFIED_BUT_UNUSABLE"
        else:
            overall = "TB_ONLY" if ok else "TB_ONLY_BUT_UNUSABLE"
        report.append({"batch": batch, "cell": cell, "tb_run": tb_run,
                       "repetition": (tb or {}).get("rollout/repetition_frac"),
                       "status": status, "overall": overall,
                       "metrics": metrics, "sanity_ok": ok, "sanity_failures": fails,
                       "trajectory_notes": notes, "job_id": row.get("job_id", "-")})

    # tb runs with no driver row: earlier ad-hoc runs. Single-source but real.
    paired_tb = {r["tb_run"] for r in report if r["tb_run"]}
    for r in tb_runs:
        if r in paired_tb:
            continue
        tb = tb_scalars(os.path.join(a.tb_root, r))
        if not tb:
            report.append({"batch": "-", "cell": r, "tb_run": r, "status": "-",
                           "overall": "NO_EVENT_DATA", "metrics": {},
                           "sanity_ok": True, "sanity_failures": [],
                           "trajectory_notes": [], "job_id": "-"})
            continue
        ok, fails, notes = sanity_check(tb)
        metrics = verify_cell(tb, None)
        has = any(m["tb"] is not None for m in metrics.values())
        overall = ("TB_ONLY" if ok else "TB_ONLY_BUT_UNUSABLE") if has else "MISSING"
        report.append({"batch": "-", "cell": r, "tb_run": r, "status": "-",
                       "repetition": (tb or {}).get("rollout/repetition_frac"),
                       "overall": overall, "metrics": metrics,
                       "sanity_ok": ok, "sanity_failures": fails,
                       "trajectory_notes": notes, "job_id": "-"})

    order = {"DISAGREE": 0, "DRIVER_ONLY": 1, "MISSING": 2, "NOT_SUCCEEDED": 3,
             "VERIFIED_BUT_UNUSABLE": 4, "TB_ONLY_BUT_UNUSABLE": 5,
             "NO_EVENT_DATA": 6, "VERIFIED": 7, "TB_ONLY": 8}
    report.sort(key=lambda r: (order.get(r["overall"], 9), r["cell"]))

    print(f"{'verdict':<24} {'cell':<24} {'mis_kl':>13} {'reward':>9} {'repet':>7}")
    print("-" * 82)
    for r in report:
        mk = r["metrics"].get("mis_kl", {}).get("tb")
        mk = f"{mk:.6g}" if mk is not None else "-"
        rw = r["metrics"].get("reward", {}).get("tb")
        rw = f"{rw:.4g}" if rw is not None else "-"
        rep = r.get("repetition")
        rep = f"{rep:.4g}" if isinstance(rep, float) else "-"
        print(f"{r['overall']:<24} {r['cell']:<24} {mk:>13} {rw:>9} {rep:>7}")

    print()
    counts = {}
    for r in report:
        counts[r["overall"]] = counts.get(r["overall"], 0) + 1
    for k in sorted(counts, key=lambda k: order.get(k, 9)):
        print(f"  {k}: {counts[k]}")

    bad = [r for r in report if r["overall"] in
           ("DISAGREE", "DRIVER_ONLY", "MISSING", "NOT_SUCCEEDED")]
    unusable = [r for r in report if r["overall"].endswith("UNUSABLE")]
    if bad:
        print("\nDO NOT PUBLISH -- no trustworthy primary data:")
        for r in bad:
            print(f"  {r['cell']}: {r['overall']} (job {r['job_id']})")
    traj = [r for r in report if r.get("trajectory_notes")]
    if traj:
        print("\nHEALTHY AT STEP 0, DEGRADED LATER (this is a result, not a defect):")
        for r in traj:
            print(f"  {r['cell']}:")
            for n in r["trajectory_notes"]:
                print(f"      {n}")
    if unusable:
        print("\nREAL RUNS, BUT NOT MEASURING WHAT WAS INTENDED:")
        for r in unusable:
            print(f"  {r['cell']}:")
            for f in r["sanity_failures"]:
                print(f"      {f}")

    if a.json:
        with open(a.json, "w") as f:
            json.dump(report, f, indent=2)
        print(f"\nwrote {a.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
