# Unverified: specs whose runs did not produce a usable result

Everything in this directory ran, or was submitted, and did **not** yield a number that any
document should quote. They are kept because a spec that failed for a known reason is worth more
than a blank -- the next attempt starts from the reason rather than from scratch -- but nothing
here has cleared the bar the parent directory's specs have.

The bar, for reference: a spec belongs in `../specs/` when its cells reached `SUCCEEDED`, passed
the step-0 sanity screens (`repetition_frac <= 0.05`, `mis_ppl_ratio <= 1.5`, `raw_reward > 0`),
and produced a value that `verify_results.py` marks `VERIFIED` or `TB_ONLY`, or -- for weight
sync -- that `collect_weight_sync.py` marks `STEADY`.

| spec | what happened | why it is not usable |
|---|---|---|
| `p2_30b.json` | 3 cells; the bf16 one completed | Generation degenerated into repetition before the first optimizer step, so `mis_kl` measured the repetition. `UNUSABLE` in the ledger. The remaining 2 cells were deliberately not submitted -- stacking fp8 on a broken baseline has nothing to measure |
| `p2_30b_temp.json` | completed | Lowered `--rollout-temperature` to 0.6 to test the sampling hypothesis. `repetition_frac` unchanged to 4 decimal places, and `mis_ppl_ratio` came back 1.7e+11, i.e. the metric itself stopped being computable. A real negative result, not a usable measurement |
| `p2_30b_probe.json` | completed | Doubled the response-length cap to 16384. Truncation stayed at 0.992, so the cap was not the constraint. Same status as above |
| `p2_30b_wcheck.json` | completed | `--check-weight-update-equal` passed, ruling out weight divergence. Again a negative result |
| `p2v_30b_ep1.json` | 4 attempts, all FAILED | CUDA OOM. EP=1 makes every rank hold all 128 experts (108.76 GiB against 139.80 GiB). PP=2 got closest, dying 12 MiB short at 125 GiB. See `../h200_results/P2V_30B_EP1_OOM.md` |
| `p3_disagg.json` | 2 cells, both SUCCEEDED | First disaggregated measurement, and the reason the matrix was re-run: mem fraction 0.85 against a colocated arm at 0.8, and only 3 rollouts, so `collect_weight_sync.py` reports `NO_STEADY_SAMPLES` once warmup is discarded. Superseded by `../specs/p3m_method_matrix.json` |
| `p3t_tp8_row.json` | submitted, incomplete | The TP8 row of the method matrix. The capacity block ended with one sync recorded out of seven. The spec itself is sound and generates cleanly -- it just needs GPUs |

## The one worth running next

`p3t_tp8_row.json`. Without it, nothing can be said about how weight sync scales with tensor
parallelism: every TP2-8 cell in this study has only 3 rollouts and therefore fails the steadiness
bar. The colocated side hinted at a 2.1x step from TP1 to TP8 under the older, weaker bar, which
would fit per-chunk CUDA IPC costing more as weights shard further, while a buffered NCCL
broadcast should be indifferent to TP. That contrast is the mechanism claim, and it is currently
unmeasured on both sides.

It needs 16 GPUs for roughly 40 minutes.
