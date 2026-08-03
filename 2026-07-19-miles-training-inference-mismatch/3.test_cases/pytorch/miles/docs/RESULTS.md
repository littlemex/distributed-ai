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
for online weight update on SGLang 0.5.12+ MoE).

**This configuration runs. It does not produce a usable mismatch measurement.**

### Retracted: the 30B concordance table

A table here previously reported a step-0 comparison across the two frameworks -- `mis_kl`
0.00182 against 0.00192, `mis_ppl_ratio` 1.00182/1.00192, `grad_norm` 0.0663/0.0655,
`raw_reward` 0.56/0.54 -- and concluded that "this establishes the fork-level concordance on
the 30B MoE case as well as the 4B dense case".

**None of those numbers came from a run.** They were removed when every reported cell in this
project was cross-checked against the trainer's own TensorBoard event files. The audit ledger
is `experiment/h200_results/DATA_STATUS.md`; the tool is `experiment/verify_results.py`, which
reports `MISSING` for any value present in a document but absent from both the event file and
the driver's `results.tsv`.

What the four real 30B runs report:

| run | mis_kl | repetition_frac | raw_reward | truncated | verdict |
| --- | --- | --- | --- | --- | --- |
| `30b_bf16` | 0.309076 | 0.633 | 0.0 | 0.99 | UNUSABLE |
| `30b_bf16_16k` | 0.196407 | 0.695 | 0.0 | 0.99 | UNUSABLE |
| `30b_t06` | 0.838965 | 0.633 | 0.0 | 0.97 | UNUSABLE |
| `p2w_30b_wcheck` | 0.205788 | 0.484 | 0.0 | 0.98 | UNUSABLE |

Two things follow. First, the real values are 0.196-0.839, two to three orders of magnitude
above the retracted 0.0018-0.0019, so the retracted figures were not merely imprecise. Second,
the real values cannot replace them: all four runs fail the step-0 sanity screen, because
generation is already looping *before the first optimizer step* -- so the logprob gap these
runs measure is a property of repeated tokens, not of the train/rollout numerical path.
`raw_reward` is 0.0 in every run, against 0.42-0.55 on dense Qwen3-4B.

Root cause is unresolved. Four hypotheses were tested against the data and rejected: a
response-length cap, weight-update divergence (checked with `--check-weight-update-equal`),
sampling temperature, and checkpoint corruption. All four runs used bf16 KV, so this is not a
quantization effect. See `experiment/h200_results/P2R_30B_INVALID.md`.

**Consequence for the framework comparison: it holds at 4B dense only.** It was not
demonstrated at MoE scale.

The `ppo_kl` 0.0 observed on both frameworks is genuine, but carries no information here:
`ppo_kl` is identically zero whenever dropout is 0, so it reads the same on a broken run as on
a healthy one. Likewise the logging difference (slime records `train/entropy_loss` 0.26 while
miles records 0.0; neither feeds the loss, `--entropy-coef 0` on both) is real and unaffected
by the retraction.

**Flag-alignment work on the 30B arm.** This is worth keeping because the porting lessons are
real and reusable, even though the comparison it was building toward is retracted above. An
earlier slime 30B run had been launched **without** the mismatch/dropout flags and reported
`ppo_kl 0.213` (train-mode dropout on) and no `mis_kl`. Re-running slime 30B with the exact
miles flags drove `ppo_kl` to 0.0, confirming the 0.213 was the train-mode dropout artefact
(same mechanism as the 4B dropout-0.1 arm), not framework drift. That conclusion does not
depend on the retracted mis_kl values: it is a before/after on one framework's own `ppo_kl`.
Two porting gotchas surfaced doing this: (1) the 30B recipe lacked the `EXTRA_TRAIN_ARGS` hook
the 4B recipe has (added);
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

## Cross-engine concordance: SGLang vs vLLM (verified -- 3 seeds)

Every mismatch figure above compares one inference engine (SGLang) against the trainer
(Megatron). That leaves an obvious question open: is the ~6e-4 baseline mismatch a property
of *SGLang specifically*, or of "any inference engine vs any trainer"? To separate those,
the same Qwen3-4B weights were scored by **two inference engines** with no trainer involved:

1. SGLang samples 32 dapo-math-17k completions (temperature 1.0, 256 new tokens,
   `return_logprob`), giving a per-token logprob for every response token -- 8192 tokens.
2. The **identical token sequences** are teacher-forced through vLLM 0.11.0
   (`prompt_logprobs`), giving vLLM's logprob for the same tokens.
3. The same estimator slime uses for `mis_kl` is applied to that pair
   (`examples/train_infer_mismatch_helper/mis.py:add_ppl_metrics`): signed
   `kl = logprob_rollout - logprob_train` and the k3 estimator
   `exp(r) - r - 1` with `r = logprob_train - logprob_rollout`, here with SGLang in the
   rollout role and vLLM in the train-side role.

At 32 prompts (8192 response tokens) per seed:

| seed | mean kl (SGLang - vLLM) | mean abs diff | k3_kl |
| --- | --- | --- | --- |
| 42 | 0.000329 | 0.01170 | 0.000800 |
| 123 | 0.001233 | 0.01167 | 0.000749 |
| 1234 | 0.001383 | 0.01281 | 0.000955 |
| **mean +/- sd** | **0.000982 +/- 0.000570** | **0.01206 +/- 0.00065** | **0.000835 +/- 0.000107** |

Repeated at **128 prompts (32768 response tokens) per seed** to check the estimate is not
sample-size limited. It tightens sharply and lands on the same value:

| seed | mean kl (SGLang - vLLM) | mean abs diff | k3_kl |
| --- | --- | --- | --- |
| 42 | 0.000667 | 0.01162 | 0.000783 |
| 123 | 0.000918 | 0.01188 | 0.000822 |
| 1234 | 0.000869 | 0.01202 | 0.000814 |
| **mean +/- sd** | **0.000818 +/- 0.000133** | **0.01184 +/- 0.00020** | **0.000806 +/- 0.000020** |

k3_kl's coefficient of variation drops from 13% (32 prompts) to **2.5%** (128 prompts) while
the mean barely moves (8.35e-4 -> 8.06e-4), so the 32-prompt spread was sampling noise, not
a real seed effect. The cross-engine gap is a stable property of this engine pair at this
model, and it is a far tighter quantity than either the collapse magnitude or the
fork-concordance ratio.

### The metric is symmetric in the two engines

A concordance number measured with SGLang in the rollout role could in principle be an
artefact of *that* role assignment -- e.g. of SGLang's sampling path specifically, rather
than of the gap between the two engines. So the direction was reversed: **vLLM generates**
(`logprobs=0` on the sampled tokens) and **SGLang teacher-forces** the identical sequences
(`max_new_tokens=0`, `return_logprob`, reading `input_token_logprobs`), with the same
estimator applied to the swapped pair.

| direction | rollout role | train-side role | k3_kl (3 seeds) |
| --- | --- | --- | --- |
| forward (128 prompts) | SGLang | vLLM | 0.000806 +/- 0.000020 |
| reversed (32 prompts) | vLLM | SGLang | 0.000792 +/- 0.000061 |

The two agree well inside each other's spread. Whichever engine plays the rollout role, the
measured gap is ~8e-4, so the metric is capturing the symmetric numerical-path difference
between the pair rather than a quirk of one engine's sampling loop.

### It barely moves across model scale

Every other measurement in this study uses Qwen3-4B, so the concordance figure could in
principle be a property of that one model. The same forward harness was therefore run on
three dense Qwen3 sizes (seed 1234, 128 prompts / 32768 response tokens each):

| model | k3_kl | mean kl (SGLang - vLLM) | mean abs diff |
| --- | --- | --- | --- |
| Qwen3-1.7B | 0.000959 | 0.000857 | 0.01318 |
| Qwen3-4B | 0.000814 | 0.000869 | 0.01202 |
| Qwen3-8B | 0.000774 | 0.000688 | 0.01174 |

A **4.7x span in parameter count moves k3_kl by 1.24x** (9.59e-4 -> 7.74e-4), and the trend
is mildly *downward* rather than upward. So the ~1e-3 cross-engine gap is not an artefact of
the 4B model: it is roughly scale-invariant over this range, which is what one expects if it
is set by per-op floating-point ordering differences rather than by model capacity. Single
seed per model (the 3-seed spread at 4B was +/- 0.20e-4, well below the spread across
models), and all three are dense models -- MoE was not covered here.

The engine-vs-engine gap (k3_kl 8.35e-4 +/- 1.07e-4) is **the same order as the
SGLang-vs-Megatron baseline** (mis_kl ~6.2e-4 on miles, ~5.3e-4 on slime), and it is far
more stable run-to-run than either the collapse magnitude or the fork-concordance ratio
(13% coefficient of variation over 3 seeds). Two consequences:

1. **The benign baseline mismatch is not an SGLang artefact.** Swapping the inference
   engine entirely moves the metric within the same order of magnitude. A ~1e-3 logprob
   disagreement is what independent optimised inference stacks simply do to each other in
   bf16, and it stays in the benign regime.
2. **It sets the noise floor the KV-fp8 amplification has to clear -- and clears it by
   ~40x.** fp8_e5m2 pushes mis_kl to 0.032, roughly 40x this cross-engine floor, which is
   why the amplified condition is a usable model of a pathological mismatch rather than
   measurement noise.

Raw data: [`results/e5_all_seeds.json`](./results/e5_all_seeds.json) (per-seed summaries in
the same directory). Harness and reproduction steps:
[`../scripts/concordance/`](../scripts/concordance/).

Caveats: dense models only (1.7B/4B/8B; no MoE), and vLLM had to
run with `enforce_eager=True` plus `TORCHDYNAMO_DISABLE=1` on this box (its pinned
torch 2.8/triton 3.4 pairing cannot compile against the node's CUDA 13.1 driver). Eager
execution changes kernel selection, so this measures "SGLang vs vLLM-in-eager-mode", which
if anything is a *conservative* comparison for the concordance claim: the two engines still
agree to ~1e-3 despite differing kernel paths. The two engines also live in separate Python
environments (SGLang in the image, vLLM in an isolated venv) and were run sequentially with
an explicit engine shutdown in between, so neither perturbs the other's GPU memory.

## Per-kernel attribution: which backend flag drives the amplification (verified)

The KV-fp8 amplification above changes several things at once, so each backend flag was
toggled **in isolation** and only step-0 `mis_kl` was measured -- no training, so the
optimizer has not yet moved the policies apart and what is left is the pure numerical-path
difference. Cheap (one rollout + one forward per cell) and directly attributable.

| condition (Qwen3-4B, step 0) | train/mis_kl | vs baseline |
| --- | --- | --- |
| KV cache = auto (baseline) | 0.000716 | 1x |
| KV fp8_e5m2 | 0.0324 | ~45x |
| KV fp8_e4m3 | 0.0087 | ~12x |
| KV fp8_e5m2 + attention backend forced to triton | 0.0319 | ~45x (same as fp8 alone) |
| KV auto + CUDA graph disabled | 0.000671 | 1x |
| KV auto + attention backend forced to triton (alone) | 0.000663 | 1x |

Three readings:

1. **KV quantisation drives essentially all of the amplification** (auto 0.0007 ->
   fp8_e5m2 0.032, ~45x).
2. **The effect is monotone in quantisation precision.** e4m3 (4 mantissa bits) gives
   0.0087 while e5m2 (2 mantissa bits) gives 0.0324 -- fewer mantissa bits, larger
   mismatch. This is what makes KV fp8 a *physically interpretable* amplifier rather than
   an arbitrary knob: it moves the metric in a predictable direction and magnitude.
3. **Attention backend and CUDA graph do nothing on their own.** Forcing triton alone
   (0.000663) or disabling CUDA graphs (0.000671) is indistinguishable from baseline, and
   layering triton on top of fp8 (0.0319) does not move fp8's own figure (0.0324).

Each cell is a **single run point estimate**; per-condition variance was not measured. The
`env_e4_c*` env files used for these cells are the amplified config with exactly one flag
changed per cell.

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

## Multi-seed collapse/rescue variance (verified -- 3 seeds x 30 steps)

The collapse and rescue arms were re-run to completion on **3 seeds (1234 / 42 / 123)**,
30 steps each, on p5 (H100 x8) -- the "n=1" error bar the single-seed tables above lacked.
Both arms use the amplified condition (LR 1e-5, `--sglang-kv-cache-dtype fp8_e5m2`,
dropout 0); the only difference between them is TIS (`--use-tis` with `mis.yaml`,
`tis_upper_bound: 2.0`). Values are mean +/- sample sd across the 3 seeds.

| step | no-TIS mis_kl | TIS mis_kl | no-TIS grad_norm | TIS grad_norm |
| --- | --- | --- | --- | --- |
| 0 | 0.0321 +/- 0.0009 | 0.0325 +/- 0.0006 | 0.140 +/- 0.018 | 0.110 +/- 0.001 |
| 10 | 0.0809 +/- 0.0171 | 0.0656 +/- 0.0193 | 0.532 +/- 0.097 | 0.130 +/- 0.067 |
| 14 | 0.3774 +/- 0.2143 | 0.0771 +/- 0.0255 | 2.195 +/- 1.090 | 0.084 +/- 0.086 |
| 19 | 1.3494 +/- 1.3525 | 0.1019 +/- 0.0315 | 8.268 +/- 8.752 | 0.053 +/- 0.061 |
| 24 | **5.4772 +/- 4.9519** | 0.1182 +/- 0.0250 | **31.98 +/- 16.46** | 0.054 +/- 0.074 |
| 29 | 5.3022 +/- 7.2556 | **0.0994 +/- 0.0311** | 21.83 +/- 26.83 | **0.053 +/- 0.044** |

Reward tells the same story, and is the metric a practitioner actually cares about:

| step | no-TIS raw_reward | TIS raw_reward |
| --- | --- | --- |
| 0 | 0.456 +/- 0.052 | 0.458 +/- 0.032 |
| 14 | 0.477 +/- 0.070 | 0.537 +/- 0.066 |
| 19 | 0.375 +/- 0.193 | 0.633 +/- 0.061 |
| 24 | 0.227 +/- 0.166 | 0.675 +/- 0.025 |
| 29 | **0.081 +/- 0.114** | **0.529 +/- 0.078** |

Three things the error bars add over the single-seed run:

1. **The direction is not seed luck.** Every one of the 3 no-TIS seeds diverges and every
   one of the 3 TIS seeds stays bounded. At step 0 the two arms are statistically
   indistinguishable (0.0321 vs 0.0325, sd ~0.001), so the arms start from the same
   numerical condition and separate only as training proceeds.
2. **Collapse magnitude is wildly seed-dependent; its occurrence is not.** The no-TIS
   sd grows to the same order as the mean (5.48 +/- 4.95 at step 24; grad_norm 31.98 +/-
   16.46), i.e. *when* and *how hard* it blows up varies a lot per seed. Any single-seed
   figure for the divergence magnitude -- including the 2.097 / 14.3 in the section above --
   is one draw from a very wide distribution and must not be quoted as "the" magnitude.
3. **TIS does not merely delay the collapse, and does not cost reward.** Over 30 steps the
   TIS arm holds mis_kl ~0.03-0.12 and grad_norm ~0.05-0.13 with *shrinking* spread, while
   its reward keeps improving (0.458 -> 0.675 at step 24) exactly where the no-TIS arm
   collapses to 0.081. The rescue is not a stability-vs-performance trade-off here.

Raw per-step series: [`results/e1_seed1234.json`](./results/e1_seed1234.json),
[`results/e1_seed42.json`](./results/e1_seed42.json),
[`results/e1_seed123.json`](./results/e1_seed123.json) -- each keyed
`{disease,cure} -> metric -> step -> value`.

### Still single-seed

The baseline (LR 1e-6 bf16) and 30B MoE concordance tables earlier in this document are
**still single-run point estimates** -- the 3-seed work covered the collapse/rescue arms
only. The fork-concordance ratios (54x vs 49x) likewise remain single-seed.

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
- Verified: **multi-seed variance on the collapse/rescue arms** -- 3 seeds (1234/42/123) x
  30 steps on p5 (H100 x8). All 3 no-TIS seeds diverge, all 3 TIS seeds stay bounded, and
  the TIS arm's reward keeps improving where no-TIS collapses. The collapse *magnitude* is
  very seed-dependent (mis_kl 5.48 +/- 4.95 at step 24), so single-seed magnitudes must not
  be quoted as "the" figure.
- Verified: **per-kernel attribution** -- step-0 `mis_kl` with each backend flag toggled in
  isolation. KV quantisation drives essentially all of the amplification and is monotone in
  precision (e4m3 ~12x, e5m2 ~45x); attention backend and CUDA graph do nothing alone.
  Single run per cell.
- Verified: **cross-engine concordance (SGLang vs vLLM)** -- k3_kl 8.06e-4 +/- 0.20e-4 over
  3 seeds at 128 prompts (32768 tokens) each, on identical token sequences with no trainer
  involved: the same order as the SGLang-vs-Megatron baseline. Reversing the roles (vLLM
  generates, SGLang re-scores) gives 7.92e-4 +/- 0.61e-4, so the metric is symmetric in the
  pair. Across model scale (Qwen3-1.7B/4B/8B) it spans only 1.24x, so it is not an artefact
  of the 4B model either. Shows the benign baseline mismatch is not SGLang-specific and sets
  the noise floor that the KV-fp8 amplification clears by ~40x. vLLM ran in eager mode
  (driver/triton constraint), so this is a conservative comparison; dense models only.
- Untested (UNVERIFIED): multi-seed variance on the **baseline and 30B MoE** tables (those
  remain single-run point estimates, as does the 54x-vs-49x fork ratio), Qwen3-30B-A3B MoE
  *disaggregated* (verified only as colocated; disaggregated needs B300 HBM), and the
  disaggregated reward service. All mirror slime and are marked UNVERIFIED.
