#!/usr/bin/env python3
"""Minimal HF Trainer fine-tune, launched under torch.distributed (gloo on CPU, nccl on GPU).

This script is started by `torchrun`, which sets RANK / WORLD_SIZE / LOCAL_RANK /
MASTER_ADDR / MASTER_PORT on every spawned process — exactly the env:// rendezvous variables
that torch.distributed and accelerate.PartialState (which TrainingArguments delegates
distributed-environment detection to) read at construction time. Under a Kubeflow PyTorchJob
these are NOT pod-level env vars: the PyTorchJob's spec.elasticPolicy makes the operator inject
PET_RDZV_BACKEND=c10d and PET_RDZV_ENDPOINT=<job>-worker-0:23456, torchrun performs the c10d
rendezvous (electing Worker-0 as the store and assigning node ranks dynamically), and only then
does torchrun export RANK / WORLD_SIZE / LOCAL_RANK / MASTER_ADDR / MASTER_PORT INTO each
training process — which is what this script reads below. No manual environment shim is needed.
"""
import os

import torch
import torch.distributed as dist
from datasets import load_dataset
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    Trainer,
    TrainingArguments,
)

MODEL_NAME = os.environ.get("MODEL_NAME", "HuggingFaceTB/SmolLM2-135M")
DATASET_NAME = os.environ.get("DATASET_NAME", "databricks/databricks-dolly-15k")
TRAIN_SAMPLES = int(os.environ.get("TRAIN_SAMPLES", "200"))
OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "/shared/output")
NUM_EPOCHS = float(os.environ.get("NUM_EPOCHS", "1"))
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "4"))
MAX_LENGTH = int(os.environ.get("MAX_LENGTH", "256"))

world_size = int(os.environ.get("WORLD_SIZE", "1"))
rank = int(os.environ.get("RANK", "0"))
use_cuda = torch.cuda.is_available()
backend = "nccl" if use_cuda else "gloo"


def log(msg):
    print(f"[rank {rank}/{world_size}] {msg}", flush=True)


def format_example(example):
    instruction = example["instruction"]
    context = example.get("context") or ""
    response = example["response"]
    if context:
        text = f"### Instruction:\n{instruction}\n\n### Context:\n{context}\n\n### Response:\n{response}"
    else:
        text = f"### Instruction:\n{instruction}\n\n### Response:\n{response}"
    return {"text": text}


def main():
    log(f"backend={backend} cuda_available={use_cuda} device_count={torch.cuda.device_count() if use_cuda else 0}")

    tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    log(f"loading model {MODEL_NAME}")
    model = AutoModelForCausalLM.from_pretrained(MODEL_NAME)

    log(f"loading dataset {DATASET_NAME} (first {TRAIN_SAMPLES} rows)")
    raw = load_dataset(DATASET_NAME, split=f"train[:{TRAIN_SAMPLES}]")
    raw = raw.map(format_example)

    def tokenize(batch):
        out = tokenizer(
            batch["text"],
            truncation=True,
            max_length=MAX_LENGTH,
            padding="max_length",
        )
        out["labels"] = out["input_ids"].copy()
        return out

    tokenized = raw.map(tokenize, batched=True, remove_columns=raw.column_names)

    # ddp_backend is passed ONLY when world_size > 1: verified by reading accelerate's
    # PartialState.__init__ that passing a non-None backend unconditionally sets self.backend,
    # and later code treats "self.backend is not None" as "call torch.distributed.get_world_size()"
    # regardless of distributed_type — so a single-process run with an explicit backend crashes
    # with "Default process group has not been initialized". Single-process runs must omit it
    # entirely and let accelerate fall through to DistributedType.NO with self.backend == None.
    trainer_kwargs = dict(
        output_dir=OUTPUT_DIR,
        num_train_epochs=NUM_EPOCHS,
        per_device_train_batch_size=BATCH_SIZE,
        logging_steps=5,
        save_strategy="epoch",
        report_to=[],
        use_cpu=not use_cuda,
        bf16=use_cuda,
    )
    if world_size > 1:
        trainer_kwargs["ddp_backend"] = backend
    args = TrainingArguments(**trainer_kwargs)

    trainer = Trainer(model=model, args=args, train_dataset=tokenized)

    log("starting training")
    trainer.train()

    # Only rank 0 writes the final model. The non-zero ranks must wait at a barrier until that
    # write finishes; otherwise they exit main() and the process group is torn down while rank 0
    # is still mid-save, which can surface as a NCCL/gloo "connection reset" on rank 0. The
    # barrier is only meaningful when a group was actually initialized (world_size > 1).
    if world_size > 1 and dist.is_initialized():
        if rank == 0:
            log(f"saving final model to {OUTPUT_DIR}/final")
            trainer.save_model(f"{OUTPUT_DIR}/final")
            tokenizer.save_pretrained(f"{OUTPUT_DIR}/final")
        dist.barrier()
        dist.destroy_process_group()
    elif rank == 0:
        log(f"saving final model to {OUTPUT_DIR}/final")
        trainer.save_model(f"{OUTPUT_DIR}/final")
        tokenizer.save_pretrained(f"{OUTPUT_DIR}/final")

    log("done")


if __name__ == "__main__":
    main()
