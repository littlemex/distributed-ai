"""TitanRL (torchtitan v0.4.0) recipes for checking trainer/generator logprob parity on one 8-GPU node.

Both recipes start from torchtitan's own `rl_grpo_qwen3_0_6b_varlen_batch_invariant` (Qwen3-0.6B,
GRPO on the alphabet-sort task, trainer TP=2 plus three TP=2 vLLM generators, strictly on-policy)
and differ only in DebugConfig on the trainer and the generator:

  bi_on   DebugConfig(batch_invariant=True, deterministic=True)  - the recipe as shipped
  bi_off  DebugConfig()                                           - default kernels

The model, topology, data, seeds and compile settings are otherwise identical, so a difference in
`bit_wise/logprob_diff/max` or `bit_wise/ratio_tokens_different/mean` comes from batch invariance alone.
W&B is turned off; TensorBoard event files and every reduced metric on the console are kept.

Run from the torchtitan repository root (the Qwen3-0.6B assets are expected under ./assets/hf/):
  python -m torchtitan.rl.train --module bi_recipes --config bi_on --output-dir /local/titanrl/bi_on
"""
import os

from torchtitan.config import DebugConfig
from torchtitan_recipes.rl.alphabet_sort import rl_grpo_qwen3_0_6b_varlen_batch_invariant

STEPS = int(os.environ.get("BI_STEPS", "30"))


def _common(c):
    c.async_loop.num_training_steps = STEPS
    c.metrics.enable_wandb = False
    c.metrics.enable_tensorboard = True
    keys = list(c.metrics.console_log_keys_train or [])
    c.metrics.console_log_keys_train = keys + ["bit_wise/", "timing/", "trainer/"]
    return c


def bi_on():
    return _common(rl_grpo_qwen3_0_6b_varlen_batch_invariant())


def bi_off():
    c = rl_grpo_qwen3_0_6b_varlen_batch_invariant()
    c.trainer.debug = DebugConfig()
    c.generator.debug = DebugConfig()
    return _common(c)
