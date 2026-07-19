# miles hardware-validation results

Real-hardware record of reproducing the parent (slime) training-inference mismatch study
on miles: single node (H200 x8, colocated GRPO, Qwen3-4B dense). The miles image
(radixark/miles + EFA) was built and GRPO was run under KubeRay on the same cluster used
for the slime study.

## What was reached

A miles GRPO step ran to completion, and the mismatch metrics were collected with the same
instrumentation as slime. weight sync (colocated), rollout, ref/log_probs, and the
Megatron backward were all exercised on hardware.

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
set by the rollout/trainer numerical-path difference, not by the RL framework. `ppo_kl` is
also 0.0 at dropout=0, consistent with slime's finding that `ppo_kl` is a train-mode
dropout artefact.

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

## Variance / additional arms (attempted, cut short by hardware)

A multi-seed baseline (to put an error bar on the concordance) and a full
collapse-then-TIS-rescue sequence were started, but the single p5en GPU node went
`NotReady` (EC2 status `impaired` -- a borrowed-cluster hardware fault, not a workload
issue) partway through the first extra seed. So the numbers above remain single-seed point
estimates; multi-seed variance and the miles collapse/rescue arms are still UNVERIFIED.

## Verified vs not (see README Verification Status)

- Verified: Qwen3-4B colocated, GRPO step completion, weight sync, baseline + KV fp8
  mismatch metrics, ppo_kl=0 at dropout=0, image build.
- Blocked: `save_model()` fails with `_pickle.UnpicklingError: pickle data was truncated`
  (Megatron distributed checkpoint `gather_object`); independent of the GRPO loop. This
  blocks the HF<->Megatron round-trip (`scripts/convert_checkpoint.sh`) and long
  checkpointing runs. Should be filed as an upstream miles issue.
- Untested: TIS rescue arm, multi-node, Qwen3-30B-A3B MoE disaggregated, the disaggregated
  reward service. All mirror slime and are marked UNVERIFIED.
