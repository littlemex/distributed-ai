# miles hardware-validation results

Real-hardware record of reproducing the parent (slime) training-inference mismatch study
on miles. The miles image (radixark/miles + EFA) was built and GRPO was run under KubeRay
on the same cluster used for the slime study. Two scopes were covered:

- **Mismatch metric arms** (baseline / KV fp8 / dropout), Qwen3-4B dense colocated on a
  single H200x8 node -- the core concordance measurements vs slime.
- **2-node GRPO** (16 GPU, EFA): Qwen3-4B dense (3 cycles) and Qwen3-30B-A3B MoE colocated
  (with distributed optimizer), including a clean apple-to-apple 30B pair vs slime.

## What was reached

miles GRPO steps ran to completion, and the mismatch metrics were collected with the same
instrumentation as slime. weight sync (colocated), rollout, ref/log_probs, and the Megatron
backward were all exercised on hardware -- on a single node and across 2 nodes over EFA.

## miles baseline mismatch metrics (step 0, LR 1e-6, dropout=0, seeds fixed)

Directly comparable to the slime baseline (both measured on the same H200 x8 node):

| Metric | miles (measured) | slime (measured, same cluster) | Concordance |
| --- | --- | --- | --- |
| train/mis_kl | 0.000632 | 0.00065 | same order (~3% apart) |
| train/mis_ppl_ratio | 1.00063 | 1.0006 | matches |
| train/mis_chi2_token | 0.00131 | 0.0012 | matches |
| train/train_rollout_logprob_abs_diff | 0.0130 | 0.0128 | matches |
| train/ppo_kl (dropout=0) | 0.0 | 0.0 | both zero |
| rollout/raw_reward | 0.531 | (same range) | - |
| perf/rollout_time | 56.7s | (same order) | - |

Conclusion: on miles too, the bf16 SGLang-vs-Megatron `mis_kl` is ~6e-4, matching slime to
the same order. This supports the parent conclusion -- the *magnitude* of the mismatch is
set by the rollout/trainer numerical-path difference, and does not shift across this
framework fork (slime -> miles; a direct fork, not an independent implementation -- see the
README concordance caveat). `ppo_kl` is also 0.0 at dropout=0, consistent with slime's
finding that `ppo_kl` is a train-mode dropout artefact.

### ppo_kl is a dropout artefact -- both arms measured on miles (step 0, LR 1e-6)

| dropout | miles ppo_kl | miles pg_clipfrac | miles mis_kl |
| --- | --- | --- | --- |
| 0 (attention+hidden dropout 0) | 0.0 | 0.0 | 0.000632 |
| 0.1 (Megatron default) | 0.3009 | 0.0471 | 0.000620 |

Turning off the flags overrides gives dropout 0.1 (the Megatron default). `ppo_kl` jumps to
0.30 and `pg_clipfrac` to 0.047, while `mis_kl` is unchanged (0.00062 either way). So on
miles too, `ppo_kl` reflects the train-mode dropout mask difference (old_log_probs computed
in eval mode with dropout off, loss log_probs in train mode with dropout on), not real
off-policy drift -- and the mismatch metric is independent of it. miles's 0.30 matches
slime's 0.31, and both go to 0.0 at dropout=0.

## KV fp8 amplification (real hardware, LR 1e-5, dropout=0)

Adding `--sglang-kv-cache-dtype fp8_e5m2` to the same Qwen3-4B bf16 amplifies the mismatch
on miles as well. Observed over the first steps:

| step | miles train/mis_kl |
| --- | --- |
| 0 | 0.0310 |
| 1 | 0.0284 |
| 2 | 0.0273 |
| 3 | 0.0267 |
| 4 | 0.0287 |

vs miles baseline 0.000632 -> ~49x at step 0. slime's same amplification was
0.0006 -> 0.0327 (~54x), same direction and order. The early steps stay flat around 0.03
(slime likewise held 0.026-0.034 early and only diverged later, around step 14-18); at 8
steps this run is short of the divergence. The SGLang engine generates correctly with the
fp8 KV cache (a correct answer with reward 1 was observed).

LR-pairing caveat: baseline is at LR 1e-6 and the fp8 run at LR 1e-5, so the amplification
factor varies dtype and LR together. Step-0 `mis_kl` is a property of the numerical path
before the optimizer diverges the policies, and both frameworks were compared under the
identical LR pairing, so the *concordance* between slime and miles holds; the amplification
factor itself is not a clean single-variable attribution.

## 2-node verification (p5en H200 x2 = 16 GPU, EFA, colocated)

After a second p5en node was secured through a capacity block, miles was run on **2 nodes
(16 GPU)** over EFA, mirroring the slime issue #1163 layout exactly (actor 2x8, rollout
sharing the same 16 GPU in colocated mode). Both GRPO cases ran to completion.

### Qwen3-4B dense, colocated, 3 GRPO cycles (`recipe/run_grpo_qwen3_4b.sh`)

| rollout | raw_reward | actor_train_tflops | perf/step_time |
| --- | --- | --- | --- |
| 0 | 0.477 | 100.4 | 119.2s |
| 1 | 0.523 | 245.4 | 73.1s |
| 2 | 0.492 | 235.7 | 81.6s |

All 3 cycles completed (job SUCCEEDED, 676s). weight sync, rollout, ref/log_probs and the
Megatron backward all ran across both nodes over EFA. `ppo_kl` stayed 0.0 at dropout=0,
consistent with the single-node arm.

### Qwen3-30B-A3B MoE, colocated, 16 GPU (`recipe/run_grpo_qwen3_30b_a3b.sh`)

Colocated actor 2x8 + `--use-distributed-optimizer` (30B static memory sharded across the
16 GPU) + `--sglang-moe-runner-backend triton --sglang-expert-parallel-size 2` (required
for online weight update on SGLang 0.5.12+ MoE). Both frameworks were run with the
**identical flags** (mismatch metrics, `--attention-dropout 0 --hidden-dropout 0`, seeds
1234/42, `mis_metrics_only.yaml`), so this is a clean apple-to-apple pair. Step 0 completed
on both (miles job SUCCEEDED in ~1223s; the slime job reached step 0 with the same config):

| Metric (step 0) | slime 30B | miles 30B | Concordance |
| --- | --- | --- | --- |
| train/ppo_kl (dropout=0) | 0.0 | 0.0 | both zero |
| train/mis_kl | 0.00182 | 0.00192 | same order (~5% apart) |
| train/mis_ppl_ratio | 1.00182 | 1.00192 | matches |
| train/mis_chi2_token | 0.00373 | 0.00415 | same order |
| train/train_rollout_logprob_abs_diff | 0.0197 | 0.0198 | matches |
| train/grad_norm | 0.0663 | 0.0655 | matches |
| train/pg_clipfrac | 0.0 | 0.0 | both zero |
| train/loss | ~0 | ~0 | both ~0 |
| rollout/raw_reward | 0.56 | 0.54 | same range |

The 30B MoE mismatch (`mis_kl` ~0.0018-0.0019) is ~3x the 4B dense figure (~0.0006) --
larger but still in the "benign" regime, and `ppo_kl` is 0.0 on **both** frameworks at
dropout=0. This establishes the fork-level concordance on the 30B MoE case as well as the
4B dense case. (One implementation difference: slime records `train/entropy_loss` 0.26
while miles records 0.0; neither feeds the loss -- `--entropy-coef 0` on both -- so it does
not affect the comparison, it is a metric-logging difference.)

**How the clean pair was obtained.** An earlier slime 30B run had been launched
**without** the mismatch/dropout flags and reported `ppo_kl 0.213`
(train-mode dropout on) and no `mis_kl`. Re-running slime 30B with the exact miles flags
drove `ppo_kl` to 0.0, confirming the 0.213 was the train-mode dropout artefact (same
mechanism as the 4B dropout-0.1 arm), not framework drift. Two porting gotchas surfaced
doing this: (1) the 30B recipe lacked the `EXTRA_TRAIN_ARGS` hook the 4B recipe has (added);
(2) `--custom-tis-function-path` must be a **dotted** module path
(`examples.train_infer_mismatch_helper.mis.compute_mis_weights_with_cp`), not the
`file.py:func` form -- `load_function` does `rpartition('.')` + `import_module`, so the
slash form fails with `ModuleNotFoundError` at the loss forward (late, after rollout); and
the framework install dir must be on `PYTHONPATH` for that dotted import to resolve
(`/root/miles` on miles; `/opt/slime` on slime -- the slime arm was run with `/opt/slime`
added to its recipe's `PYTHONPATH`).

**Topology note.** Both frameworks were verified in **30B MoE colocated on 16 GPU**, not
the "30B disaggregated" layout the README table originally listed as the target. Colocated
16-GPU with distributed optimizer is what actually fits 30B on H200 (141GB); B300 (288GB)
is what allows the disaggregated actor-8 layout. 30B disaggregated on H200 remains
UNVERIFIED.

## Variance / additional arms (attempted, cut short by hardware)

A multi-seed baseline (to put an error bar on the concordance) and a full
collapse-then-TIS-rescue sequence were started, but the single p5en GPU node went
`NotReady` (EC2 status `impaired` -- a borrowed-cluster hardware fault, not a workload
issue) partway through the first extra seed. So the numbers above remain single-seed point
estimates; multi-seed variance and the miles collapse/rescue arms are still UNVERIFIED.

## Verified vs not (see README Verification Status)

- Verified: Qwen3-4B colocated (single node + 2-node 3-cycle), Qwen3-30B-A3B MoE colocated
  on 2 nodes (16 GPU), GRPO step completion, weight sync, baseline + KV fp8 mismatch
  metrics, ppo_kl=0 at dropout=0 (4B and 30B), clean 30B slime-vs-miles pair, 2-node EFA
  (busbw 190-257 GB/s), image build.
- Blocked: `save_model()` fails with `_pickle.UnpicklingError: pickle data was truncated`
  (Megatron distributed checkpoint `gather_object`); independent of the GRPO loop. This
  blocks the HF<->Megatron round-trip (`scripts/convert_checkpoint.sh`) and long
  checkpointing runs. Should be filed as an upstream miles issue.
- Untested (UNVERIFIED): TIS rescue arm, multi-seed variance, the collapse/rescue sequence,
  Qwen3-30B-A3B MoE *disaggregated* (verified only as colocated; disaggregated needs B300
  HBM), and the disaggregated reward service. All mirror slime and are marked UNVERIFIED.
