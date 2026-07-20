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

Comparison is at the matched condition (dropout=0). slime's dropout=0 run measured
`mis_kl` 0.00053 (its 0.00065 figure quoted elsewhere is the dropout=0.1 run -- see
PPOKL_ROOTCAUSE). slime's own three runs span mis_kl 0.00053-0.00074 (~±17% run-to-run), so
the honest claim is "same order, within slime's own run-to-run spread", NOT a tight percent
match.

| Metric | miles (dropout=0) | slime (dropout=0) | Concordance |
| --- | --- | --- | --- |
| train/mis_kl | 0.000632 | 0.00053 | same order (within slime's 0.00053-0.00074 spread) |
| train/mis_ppl_ratio | 1.00063 | ~1.0005 | same order |
| train/train_rollout_logprob_abs_diff | 0.0130 | 0.0129 | matches |
| train/ppo_kl (dropout=0) | 0.0 | 0.0 | both zero |
| rollout/raw_reward | 0.531 | (same range) | - |

Conclusion: on miles too, the bf16 SGLang-vs-Megatron `mis_kl` is ~6e-4, the same order as
slime and inside slime's own run-to-run spread. This supports the parent conclusion -- the *magnitude* of the mismatch is
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
(slime likewise held 0.026-0.034 early and only ran away from step >=14); this short probe
was stopped at 8 steps (table shows steps 0-4), before the divergence. The full through-
collapse trajectory is in the "Collapse arm" section below. The SGLang engine generates
correctly with the fp8 KV cache (a correct answer with reward 1 was observed).

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
| train/mis_kl | 0.00182 | 0.00192 | same order (single-run point estimates; cf. slime's ~±17% run-to-run spread at 4B) |
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

## Collapse arm: KV fp8 amplification driven to divergence (verified)

Running the KV fp8 amplified config (LR 1e-5, dropout 0, `--sglang-kv-cache-dtype
fp8_e5m2`, no TIS) out to 25 steps reproduces slime's late-training collapse on miles. The
mismatch is quiet for the first ~8 steps and then runs away:

| step | train/mis_kl | train/grad_norm |
| --- | --- | --- |
| 0 | 0.033 | 0.22 |
| 8 | 0.034 | 0.33 |
| 10 | 0.059 | 0.43 |
| 12 | 0.059 | 0.66 |
| 14 | 0.151 | 1.34 |
| 16 | 0.177 | 1.92 |
| 18 | 0.426 | 2.88 |
| 19 | 0.504 | 4.59 |
| 22 | 0.807 | 5.78 |
| 24 | **2.097** | **14.3** |

On this miles run the onset is clear from the data itself: `mis_kl` is flat (~0.03) through
step 8, roughly doubles by step 10-12 (0.059), and then runs away from step 14 (0.151) to
step 24 (2.097, ~64x its step-0 value), with `grad_norm` climbing 0.22 -> 14.3 over the same
span. So the divergence *onset* is around step 10-12 and becomes unmistakable by step 14 --
the same late-training regime slime reported. (These per-step numbers are the precise
reference used across both write-ups: quiet <=8, doubling ~10-12, runaway >=14.) This confirms on miles
that the KV fp8 rollout/train numerical gap, left uncorrected, destabilises GRPO training.

## TIS rescue arm (verified -- collapse fully suppressed over 30 steps)

The same KV fp8 config **with** TIS enabled (`--use-tis`, `mis.yaml`; identical seed and LR)
was run to 30 steps. TIS turns the mismatch importance ratio into an actual loss correction,
and it **held both `mis_kl` and `grad_norm` flat right through the region where the no-TIS
arm blew up** -- the decisive rescue result:

| step | no-TIS mis_kl / grad_norm | TIS mis_kl / grad_norm |
| --- | --- | --- |
| 0 | 0.033 / 0.22 | 0.033 / 0.13 |
| 14 | 0.151 / 1.34 | ~0.04 / ~0.15 |
| 19 | 0.504 / 4.59 | ~0.04 / ~0.13 |
| 24 | **2.097 / 14.3** | 0.045 / 0.14 |
| 29 | (diverging) | **0.028 / 0.11** |

Without TIS the run runs away (mis_kl 0.033 -> 2.10, grad_norm 0.22 -> 14.3 by step 24);
with TIS, over the full 30 steps `mis_kl` stays ~0.03-0.045 and `grad_norm` ~0.11-0.22 --
no divergence at all. This is slime's "cap-limited importance sampling rescues the collapse"
result reproduced on miles: same amplified condition, TIS the only difference, collapse
present without it and absent with it.

## Multi-seed variance (UNVERIFIED)

A multi-seed baseline (to put an error bar on the concordance) was started but the single
p5en GPU node went `NotReady` (EC2 status `impaired` -- a borrowed-cluster hardware fault,
not a workload issue) partway through the first extra seed. The baseline/30B numbers above
remain single-seed point estimates.

## Verified vs not (see README Verification Status)

- Verified: Qwen3-4B colocated (single node + 2-node 3-cycle), Qwen3-30B-A3B MoE colocated
  on 2 nodes (16 GPU), GRPO step completion, weight sync, baseline + KV fp8 mismatch
  metrics, ppo_kl=0 at dropout=0 (4B and 30B), clean 30B slime-vs-miles pair, 2-node EFA
  (busbw 190-257 GB/s), image build, and the **KV fp8 collapse arm** (mis_kl 0.033 -> 2.10,
  grad_norm 0.22 -> 14.3 over 25 steps; matches slime's late-training divergence).
- Blocked: `save_model()` fails with `_pickle.UnpicklingError: pickle data was truncated`
  (Megatron distributed checkpoint `gather_object`); independent of the GRPO loop. This
  blocks the HF<->Megatron round-trip (`scripts/convert_checkpoint.sh`) and long
  checkpointing runs. Should be filed as an upstream miles issue.
- Verified: the TIS rescue arm ran the full 30 steps and kept mis_kl ~0.03-0.045 /
  grad_norm ~0.11-0.22 throughout -- no divergence, where the no-TIS arm hit mis_kl 2.10 /
  grad_norm 14.3 by step 24. The collapse-vs-rescue contrast (TIS the only difference) is
  the paper's rescue result reproduced on miles.
- Untested (UNVERIFIED): multi-seed variance, Qwen3-30B-A3B MoE *disaggregated* (verified
  only as colocated; disaggregated needs B300 HBM), and the disaggregated reward service.
  All mirror slime and are marked UNVERIFIED.
