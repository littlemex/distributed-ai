# TitanRL batch-invariant mode: are trainer and generator logprobs bitwise identical?

In RL post-training the generator (vLLM) samples completions and reports their per-token log-probabilities, and the trainer recomputes the same log-probabilities in a different batch layout. Kernels that pick their reduction order from the batch shape make the two disagree slightly, which blurs whether a bug or numerics caused a divergence. torchtitan's RL stack (TitanRL, `torchtitan/rl` in v0.4.0) has a batch-invariant mode that routes both sides through the same deterministic kernels ([`BITWISE_PARITY.md`](https://github.com/pytorch/torchtitan/blob/v0.4.0/torchtitan/rl/BITWISE_PARITY.md)). This investigation runs the same on-policy GRPO job with the mode on and off and compares the trainer-versus-generator differences the trainer logs every step.

| Recipe (`scripts/bi_recipes.py`) | DebugConfig on trainer and generator |
|---|---|
| `bi_on` | `batch_invariant=True, deterministic=True` (torchtitan's `rl_grpo_qwen3_0_6b_varlen_batch_invariant` as shipped) |
| `bi_off` | defaults |

Both use Qwen3-0.6B, the alphabet-sort task, a TP=2 trainer and three TP=2 generators on 8 GPUs, `target_offpolicy_steps=0`, and 30 steps. Nothing else differs.

## What is compared

| Metric (logged by the trainer every step) | Meaning |
|---|---|
| `bit_wise/logprob_diff/max` | Largest absolute difference between the trainer's and the generator's logprob of a sampled token |
| `bit_wise/logprob_diff/mean` | Mean of the same |
| `bit_wise/ratio_tokens_different/mean` | Fraction of tokens whose logprobs are not bitwise equal |
| Step and generator timings | The cost of the deterministic kernels |

The expectation from torchtitan's own measurement (Qwen3-8B, 8x H100) is zero for all three with the mode on.

## Files

```
scripts/bi_recipes.py      bi_on and bi_off (W&B off, TensorBoard on, extra console keys)
scripts/summarize.py       one table from both console logs
tasks/10-rl-env.json       a separate torchtitan v0.4.0 checkout, scripts/install_rl_env.sh, Qwen3-0.6B
tasks/20-parity.json       both runs and the summary
```

## Versions

`scripts/install_rl_env.sh` installs PyTorch, torchvision and vLLM nightlies from one CUDA index together, and torchstore and `batch_invariant_ops` from git main, by design: a vLLM nightly must match the PyTorch nightly's build date. These cannot be pinned to a release. The exact versions installed are recorded in `pip-freeze.txt` with the results.

## Run

```bash
cd ../2026-11-10-p5e-single-node-campaign
./3.run.sh 2026-11-10-torchtitan-rl-batch-invariant/tasks/10-rl-env.json
./3.run.sh 2026-11-10-torchtitan-rl-batch-invariant/tasks/20-parity.json
```

## Results

Measured on 2026-11-10 (p5e.48xlarge, sa-east-1), 30 on-policy steps per recipe. Raw records: [`results/p5e-2026-11-10/`](results/p5e-2026-11-10).

| Recipe | `bit_wise/logprob_diff/max` (max over steps) | `bit_wise/logprob_diff/mean` (mean over steps) | Tokens not bitwise equal | Step time (median) |
|---|---|---|---|---|
| `bi_on` | 0.0 | 0.0 | 0.0 % | 3.4 s |
| `bi_off` | 0.89 | -0.0003 | 42.6 % | 4.4 s |

With batch-invariant mode on, the trainer and the generator agreed bitwise on every sampled token at every step. With it off, 42.6 % of tokens differed and the largest single difference was 0.89 nats. The step time does not show the cost of the deterministic kernels in this run: Qwen3-0.6B on alphabet sort is small enough that a step is dominated by orchestration, and the order of the two runs (bi_on first) also differs. The nightly versions installed are in `pip-freeze.txt`.

## Contributing upstream

awsome-distributed-ai has no torchtitan RL example and nothing that measures trainer and generator logprob mismatch; slime and miles run on HyperPod EKS only. The rule there is to extend an existing directory first, so this belongs under `examples/training/torchtitan/` as an RL subdirectory with its own environment script, since its dependencies (vLLM, Monarch, nightlies) differ from the pretraining example.
