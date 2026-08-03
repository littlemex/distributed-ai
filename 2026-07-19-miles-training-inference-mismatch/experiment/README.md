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
| `specs/*.json` | One spec per experiment. Everything that varies between cells lives here, not in the code. |
| `h200_results/*.md` | Findings, with the run names behind each number. |

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
