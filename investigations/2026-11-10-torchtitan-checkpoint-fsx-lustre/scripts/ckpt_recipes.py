"""torchtitan v0.4.0 recipes for timing checkpoint saves of Llama 3 8B on one 8-GPU node.

Every recipe trains the 8B model from random init with the tokenizer and the C4 sample that ship in
the torchtitan repository (no gated Hugging Face assets), FSDP over the 8 GPUs, and saves a full
checkpoint (model + optimizer + scheduler) every CKPT_INTERVAL steps. Only the checkpointer differs:

  ckpt_dcp_sync          DCP, async_mode="disabled": training stops until every byte is written
  ckpt_dcp_async         DCP, async_mode="async": a background thread writes, training resumes earlier
  ckpt_dcp_async_pinned  DCP, async_mode="async_with_pinned_mem": copy to pinned host memory, then write
  ckpt_torch_checkpointing  torch_checkpointing backend (TorchCheckpointingManager), default settings

Where the files go is chosen at launch with --output-dir, so the same recipe runs against FSx for
Lustre and against the local instance store.

Run from the torchtitan repository root (the C4 sample path is relative):
  NGPU=8 MODULE=ckpt_recipes CONFIG=ckpt_dcp_async ./run_train.sh --output-dir /fsx/ckpt/dcp_async
"""
import os
from typing import cast

from torchtitan.components.checkpointer.dcp import CheckpointManager
from torchtitan.components.checkpointer.torch_checkpointing import TorchCheckpointingManager
from torchtitan.components.data import ConcatThenSplitPackingConfig, GrainDataLoader
from torchtitan.components.data.text_datasets import DATASETS
from torchtitan.components.loss import ChunkedLossWrapper, CrossEntropyLoss
from torchtitan.components.optim import AdamW, Optim, OptimizersContainer
from torchtitan.config import TrainingConfig
from torchtitan.config.parallelism import ParallelismConfig
from torchtitan.distributed.activation_remat import DefaultActivationRematConfig
from torchtitan.models.common.config_utils import decoder_vocab_size
from torchtitan.models.llama3 import build_model_config
from torchtitan.observability.metrics import MetricsProcessor
from torchtitan.trainer import Trainer

STEPS = int(os.environ.get("CKPT_STEPS", "21"))
INTERVAL = int(os.environ.get("CKPT_INTERVAL", "5"))
SEQ_LEN = int(os.environ.get("CKPT_SEQ_LEN", "8192"))


def _base(checkpointer) -> Trainer.Config:
    parallelism = ParallelismConfig()
    # Flex attention (pure PyTorch): the default varlen backend needs FlashAttention 3 (flash_attn_interface), which
    # is not part of torchtitan's requirements, and the attention kernel does not affect checkpointing.
    model_config = build_model_config("8B", seq_len=SEQ_LEN, attn_backend="flex", parallelism=parallelism)
    tokens = model_config.max_context_length
    return Trainer.Config(
        loss=ChunkedLossWrapper.Config(loss_fn=CrossEntropyLoss.Config(global_vocab_size=decoder_vocab_size(model_config))),
        hf_assets_path="./tests/assets/tokenizer",
        metrics=MetricsProcessor.Config(log_freq=1),
        model=model_config,
        parallelism=parallelism,
        optim=Optim.Config(optimizer=OptimizersContainer.Config(optimizers=[AdamW.Config(pattern=r".*", lr=3e-4)])),
        training=TrainingConfig(num_tokens_per_microbatch_per_dp_rank=tokens, max_context_length=tokens, steps=STEPS),
        dataloader=GrainDataLoader.Config(
            dataset=ConcatThenSplitPackingConfig(dataset=DATASETS["c4_test"]),
        ),
        checkpointer=checkpointer,
        activation_remat=DefaultActivationRematConfig(),
        validator=None,
    )


def _dcp(mode: str) -> CheckpointManager.Config:
    # keep_latest_k=0 keeps every step, so purging never overlaps a measured save.
    return CheckpointManager.Config(folder="checkpoint", interval=INTERVAL, async_mode=mode,
                                    last_save_model_only=False, keep_latest_k=0)


def ckpt_dcp_sync() -> Trainer.Config:
    return _base(_dcp("disabled"))


def ckpt_dcp_async() -> Trainer.Config:
    return _base(_dcp("async"))


def ckpt_dcp_async_pinned() -> Trainer.Config:
    return _base(_dcp("async_with_pinned_mem"))


def ckpt_torch_checkpointing() -> Trainer.Config:
    return _base(cast(CheckpointManager.Config, TorchCheckpointingManager.Config(
        folder="checkpoint", interval=INTERVAL, last_save_model_only=False, keep_latest_k=0)))
