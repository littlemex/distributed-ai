# Experiment harness

The driver, instrumentation, and analysis used for the training-inference mismatch runs in
this directory. Roughly 70 runs on H100 and H200 capacity blocks went through this code.

## Why it looks like this

An earlier version of this harness reported six cells that had never run. The driver could
not distinguish "the job finished and produced this number" from "no job was submitted", so a
blank was indistinguishable from a measurement and a blank got filled in. Most of the design
below exists to make that specific failure impossible rather than merely unlikely.

- Every terminal state is explicit: `SUCCEEDED`, `FAILED`, `STOPPED`, `NO_JOB`, `TIMEOUT`,
  `NOT_FOUND`, `UNKNOWN`. Metric columns are written only for `SUCCEEDED`; every other path
  writes `-`. A number in the results file always means a job produced it.
- `verify_results.py` re-reads the trainer's own TensorBoard event files and compares them
  against the driver's results file. A value counts as verified only when two sources written
  by different code paths agree.
- The env file that was submitted, the base env it sourced, the driver's own hash, and the
  hardware description are all frozen next to the results, so a row can be traced back to its
  conditions after the cluster is gone.

## Layout

| path | what it does |
|---|---|
| `lib/experiment.sh` | Batch driver. Submits a cell, waits for a terminal state, recovers the job log, extracts metrics, appends one row. |
| `run_batch.sh` | Entry point. Sources the library by absolute path so a stale copy in the working directory cannot run instead. |
| `lib/gen_cells.py` | Generates per-cell env files from a JSON spec and freezes the base env's contents alongside them. |
| `mis_dump.py` | Per-token logprob instrumentation, injected through `--custom-tis-function-path`. |
| `analyze_position_profile.py` | Position profile: slope of the gap against absolute position, plus the variance-scaling exponents. |
| `pool_seeds.py` | Pools slopes across seeds and reports a seed-level interval. |
| `verify_results.py` | The audit described above. |
| `test_harness.py` | Regression tests for the guarantees above. Every test corresponds to a path by which a wrong number could once have reached a document. |
| `specs/*.json` | One spec per experiment whose runs produced a usable number. Everything that varies between cells lives here, not in the code. |
| `unverified/specs/*.json` | Specs whose runs failed, were superseded, or did not finish. Kept with the reason attached, because a spec that failed for a known reason beats a blank. `unverified/README.md` says which and why. |
| `collect_weight_sync.py` | Reads weight sync timings from TensorBoard and decides whether "steady" can be claimed: discard 3 warmup samples, then require >=4 with CV <=5% and no drift. Exits non-zero if any cell falls short. |
| `test_placement_guards.py` | Feeds the same invalid layouts to the spec generator and to the recipe, and requires both to reject them for the same stated reason. |
| `moe_probe/` | Standalone SGLang harness, outside the GRPO loop, that located the 30B MoE repetition in expert parallelism. |
| `h200_results/*.md` | Findings, with the run names behind each number. |

## The tests are the point

```bash
python3 test_harness.py      # needs numpy; no cluster, tensorboard or GPU required
```

An audit in 2026-08 attacked the harness itself rather than the results, asking where a wrong
number could still get through. It found eleven paths, all now closed and all now tested. The
ones worth knowing about, because they were quiet rather than loud:

- `inf == inf` is true in Python, so a diverged run's `grad_norm=inf` matched itself across
  both sources and earned a `VERIFIED` stamp.
- A run that recorded none of the three sanity tags was reported as having passed the sanity
  screen, with zero screens actually applied. `nan` did the same thing numerically, since both
  `nan > threshold` and `nan <= threshold` are false.
- A cell whose `mis_kl` was missing but whose `reward` verified was printed as `VERIFIED`.
- The dump directory's multi-run guard only recognised run ids made of digits or lowercase hex,
  so a Ray submission id slipped past it and two runs could be pooled undetected.
- One `nan` token made the bootstrap interval `nan`, and a `nan` interval fails both the
  "excludes zero" tests -- landing on the `flat: no accumulation detected` branch. A directory
  of garbage would have printed a confident negative result.
- The t-table rounded off-table degrees of freedom the wrong way, returning critical values
  *below* the true ones and narrowing every interval that used them.

New verdicts exist so that "not checked" can no longer look like "checked and fine":
`NONFINITE`, `PARTIAL`, `UNSCREENED`, `AMBIGUOUS_PAIRING`, `TB_ONLY_UNCONFIRMED`.

Every published number was re-derived on the same hardware after these changes and none moved:
the ledger's verified cells, the position-profile slope (`-3.212623e-07`, `alpha_within` 1.03),
and the four-seed pooled interval all reproduced exactly, and no verdict changed. On the real
data the new guards fire zero times -- no non-finite tokens, no duplicates across all fourteen
dump directories, no ambiguous pairings. These were latent holes, not active corruption.

## Reading the results

`h200_results/DATA_STATUS.md` is the ledger and takes precedence over any prose. It lists
which runs are verified against two sources, which have only the trainer's event file, and
which produced real numbers that nonetheless measure the wrong thing (the 30B MoE runs, where
generation degenerated into repetition and the metric tracked that rather than quantisation).

Three findings are worth reading with their caveats attached:

- `PP_POSITION_PROFILE.md` — the accumulated error grows like T, not T squared, across all 12
  runs. It also records a conclusion that had to be withdrawn: a single seed produced an
  interval that excluded zero, and three more seeds showed the sign was not stable. A
  bootstrap over sequences within one run says nothing about the seed changing what the model
  generates.
- `P2M_MODEL_SCALE.md` — whether the quantisation multiplier depends on model size turns out
  to depend on which precision you ask about. With four seeds on each of two models, bf16 and
  e5m2 separate cleanly and e4m3 does not.
- `P2R_30B_INVALID.md` — the 30B MoE configuration completes and cannot train. Four candidate
  causes ruled out by measurement, root cause unresolved.

## What was measured on H200, and what was not

This table exists because a claim reached the slides and the article that the measurements do
not support. "Colocated weight sync is about 5x slower than disaggregated" came from B300 with
slime, and the H200 side of that comparison had never been run -- the recipe hardcoded
`--colocate` while reading `COLOCATE` only for a banner, so the disaggregated arm was
unreachable. When it was finally measured, the ratio was 2.84x, not 5.1x.

Read this table before quoting any weight sync number.

### miles

| item | state | value |
|---|---|---|
| mismatch (`mis_kl`) | **done** | 8 VERIFIED cells: 4B/8B x bf16/e4m3/e5m2, three position-profile arms, the collapse arm, the LR control |
| weight sync, colocated TP1 | **done, STEADY** | **0.482s** (CV 0.012, 7 rollouts, mem fraction 0.8) |
| weight sync, disaggregated TP1 | **done, STEADY** | **0.170s** (CV 0.013; transfer proper 0.146s) |
| mem fraction sensitivity | **done, STEADY** | 0.80 -> 0.85 moves it 1.8%, negligible against the 0.312s method difference |
| weight sync, colocated TP2/4/8 | measured, **not quotable** | 3 rollouts each, so `NO_STEADY_SAMPLES` once the first 3 samples are discarded |
| weight sync, disaggregated TP8 | **not done** | Submitted; the capacity block ended first (only the 12.7s first sync landed) |
| 30B MoE mismatch | **not measurable** | EP>1 degenerates, EP=1 OOMs. Four attempts, all FAILED. See `h200_results/P2V_30B_EP1_OOM.md` |
| `flush_cache` cost alone | **not done** | The one thing blocking a split of the 2.84x into transfer vs placement |
| weight sync share of a step | **not done** | A step is ~100s, so 0.3s is ~0.3%. Quote the share alongside the ratio |

### slime

| item | state | value |
|---|---|---|
| mismatch (`mis_kl`) | incidental | 0.000615 (`slime_baseline`), close to miles' 0.000627 |
| weight sync, colocated | **incidental, provenance lost** | 1.096 / 0.904 / 0.882s. Left over from an upstream smoke check on a different cluster (`slime-ray-*`) on 08-02. No launch log survives, so the TP degree and every other setting are unknown |
| weight sync, disaggregated | **not done** | Never run |
| re-measurement at 7 rollouts | **not done** | The existing data is 3-rollout equivalent, so it cannot clear the steadiness bar either |

### Consequence: the slime numbers cannot carry a comparison

An apple-to-apple comparison exists for exactly one combination, H200 with miles. The slime
colocated figure comes from a different cluster on a different day with no record of its
configuration, so differencing it against miles measures an unknown mixture of framework,
cluster and settings. **It is not usable as evidence of a framework difference, and no document
should present it as one.**

| claim | usable? | why |
|---|---|---|
| "On H200/miles, disaggregated is 2.84x faster" | **yes** | Both arms STEADY, mem fraction matched, the argv differs only by `--colocate` |
| "That difference is the placement's cost, not the transfer's" | **yes** | Only the colocated path calls `flush_cache` on every sync (`update_weight_from_tensor.py:213-215`) |
| "slime is ~1.8x slower than miles" | **no** | Different cluster, different day, no launch log, TP unknown |
| "Disaggregated also wins under slime" | **no** | Never measured |
| "Raising TP slows colocated weight sync" | **no** | Every TP2-8 cell is `NO_STEADY_SAMPLES` |

## Running it

```bash
python3 lib/gen_cells.py specs/<spec>.json --outdir <run-dir>

EXP_ROOT=/fsx/exp EXP_NAME=<batch> ENV_PREFIX=env_<prefix>_ RUN_DIR=<run-dir> \
  bash run_batch.sh <cell> <cell> ...

python3 verify_results.py --json /fsx/exp/VERIFICATION.json
```

`EXP_ROOT` must be on shared storage. The driver was rewritten because results written under
`/tmp` on a Ray pod were reclaimed while the jobs themselves had succeeded.

The per-token dump only writes under context-parallel size 1 and only from tensor-parallel
rank 0. Under context parallelism Megatron splits a sequence into zigzag chunks, so a rank's
slice has no recoverable token positions; and every tensor-parallel rank holds identical
logprobs, so collecting them all would multiply the apparent sample count and shrink the
bootstrap interval that the conclusion is read from. Both conditions fail closed rather than
guessing.
