#!/usr/bin/env python3
"""Minimal MNIST MLP trained with DistributedDataParallel, launched under torch.distributed
(gloo on CPU, nccl on GPU).

Adapted from awsome-distributed-ai's `3.test_cases/pytorch/ddp/ddp.py` (itself derived from
pytorch/examples multigpu_torchrun.py). The rendezvous setup matches the awsome reference:
the PyTorchJob's elasticPolicy points torchrun at an etcd Service (rdzvBackend: etcd), which
assigns node ranks dynamically and survives individual Worker restarts. After rendezvous,
torchrun exports RANK / WORLD_SIZE / LOCAL_RANK / MASTER_ADDR / MASTER_PORT into each
training process — which is what argless init_process_group() reads below. The rendezvous
backend (etcd vs c10d) is orthogonal to the communication backend (gloo vs nccl).

Two changes from the upstream sample for shared-filesystem operation:

  1. The MNIST data and the snapshot live on the shared PVC mount (/shared), not a per-node
     local disk. Because every rank sees the same filesystem, only rank 0 downloads MNIST; the
     others wait at a barrier and then read the same copy. Concurrent downloads to one shared
     path race and can corrupt the extracted archive.

  2. Only rank 0 writes the snapshot. The upstream Trainer._save_snapshot has no rank guard —
     harmless when each rank writes its own local path, but on a shared mount all ranks writing
     the same file concurrently is a corruption risk.

mlflow is optional: it is imported lazily only when USE_MLFLOW=1, so the image needs no mlflow
dependency at all (torch + torchvision come bundled with the pytorch/pytorch base image).
"""
import os

import torch
import torch.distributed as dist
import torch.nn as nn
import torch.nn.functional as F
from torch.distributed import destroy_process_group, init_process_group
from torch.nn.parallel import DistributedDataParallel as DDP
from torch.utils.data import DataLoader
from torch.utils.data.distributed import DistributedSampler
from torchvision import datasets, transforms

OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "/shared/output")
# MNIST is downloaded once and reused across runs, so it is deliberately NOT under the
# per-run OUTPUT_DIR — it sits at a shared, run-independent path on the same mount.
DATA_DIR = os.environ.get("DATA_DIR", "/shared/mnist-data")
SNAPSHOT_PATH = os.environ.get("SNAPSHOT_PATH", os.path.join(OUTPUT_DIR, "snapshot.pt"))
TOTAL_EPOCHS = int(os.environ.get("TOTAL_EPOCHS", "3"))
SAVE_EVERY = int(os.environ.get("SAVE_EVERY", "1"))
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "32"))
USE_MLFLOW = os.environ.get("USE_MLFLOW", "0") == "1"
TRACKING_URI = os.environ.get("TRACKING_URI") or f"file://{os.environ.get('HOME', '/root')}/mlruns"

world_size = int(os.environ.get("WORLD_SIZE", "1"))
rank = int(os.environ.get("RANK", "0"))
local_rank = int(os.environ.get("LOCAL_RANK", "0"))
use_cuda = torch.cuda.is_available()
backend = os.environ.get("DDP_BACKEND", "nccl" if use_cuda else "gloo")


def log(msg):
    print(f"[rank {rank}/{world_size}] {msg}", flush=True)


class MLP(nn.Module):
    def __init__(self):
        super().__init__()
        self.flatten = nn.Flatten()
        self.linear_relu_stack = nn.Sequential(
            nn.Linear(28 * 28, 512),
            nn.ReLU(),
            nn.Linear(512, 512),
            nn.ReLU(),
            nn.Linear(512, 10),
        )

    def forward(self, x):
        return self.linear_relu_stack(self.flatten(x))


def ddp_setup():
    # Argless init_process_group() uses the env:// rendezvous: WORLD_SIZE / RANK / MASTER_ADDR /
    # MASTER_PORT are already exported by torchrun (see the module docstring). nccl on GPU,
    # gloo on CPU — the only knob that differs between the two paths.
    log(f"backend={backend} cuda_available={use_cuda} device_count={torch.cuda.device_count() if use_cuda else 0}")
    init_process_group(backend=backend)


class Trainer:
    def __init__(self, model, train_data, optimizer, save_every, snapshot_path):
        self.rank = rank
        self.train_data = train_data
        self.optimizer = optimizer
        self.save_every = save_every
        self.snapshot_path = snapshot_path
        self.epochs_run = 0
        self.device = torch.device(f"cuda:{local_rank}" if use_cuda else "cpu")
        model = model.to(self.device)

        # Resume is a read-only load of the shared snapshot, safe to do on every rank. Must
        # happen BEFORE the DDP wrap: load_state_dict targets the bare module, and DDP then
        # broadcasts rank 0's (now-restored) weights to the others at construction anyway.
        if os.path.exists(snapshot_path):
            self._load_snapshot(model, snapshot_path)

        self.model = DDP(model, device_ids=[local_rank] if use_cuda else None)

    def _load_snapshot(self, model, snapshot_path):
        snapshot = torch.load(snapshot_path, map_location=self.device)
        model.load_state_dict(snapshot["MODEL_STATE"])
        self.epochs_run = snapshot["EPOCHS_RUN"]
        log(f"resuming from snapshot at epoch {self.epochs_run}")

    def _run_epoch(self, epoch):
        self.train_data.sampler.set_epoch(epoch)
        total_loss = 0.0
        for source, targets in self.train_data:
            source, targets = source.to(self.device), targets.to(self.device)
            self.optimizer.zero_grad()
            loss = F.cross_entropy(self.model(source), targets)
            loss.backward()
            self.optimizer.step()
            total_loss += loss.item()
        avg_loss = total_loss / len(self.train_data)
        log(f"epoch {epoch} | steps {len(self.train_data)} | loss {avg_loss:.4f}")
        return avg_loss

    def _save_snapshot(self, epoch):
        # Rank 0 only — see module docstring change (3). self.model is the DDP wrapper, so the
        # unwrapped weights are on .module.
        os.makedirs(os.path.dirname(self.snapshot_path) or ".", exist_ok=True)
        torch.save({"MODEL_STATE": self.model.module.state_dict(), "EPOCHS_RUN": epoch}, self.snapshot_path)
        log(f"epoch {epoch} | snapshot saved to {self.snapshot_path}")

    def train(self, max_epochs, use_mlflow, tracking_uri):
        mlflow_ctx = _maybe_start_mlflow(use_mlflow and self.rank == 0, tracking_uri, max_epochs, self.optimizer)
        for epoch in range(self.epochs_run, max_epochs):
            avg_loss = self._run_epoch(epoch)
            if self.rank == 0 and epoch % self.save_every == 0:
                self._save_snapshot(epoch)
            if mlflow_ctx is not None:
                import mlflow

                mlflow.log_metric("train_loss", avg_loss, step=epoch)
        if mlflow_ctx is not None:
            mlflow_ctx.__exit__(None, None, None)


def _maybe_start_mlflow(enabled, tracking_uri, max_epochs, optimizer):
    # Lazy import so the image does not need mlflow unless USE_MLFLOW=1. Returns the active run
    # context (to close later) or None. Any failure downgrades to no-tracking rather than
    # aborting training.
    if not enabled:
        log("mlflow disabled")
        return None
    try:
        import mlflow

        mlflow.set_tracking_uri(tracking_uri)
        mlflow.set_experiment("mnist_ddp")
        ctx = mlflow.start_run()
        ctx.__enter__()
        mlflow.log_params({"model": "MLP", "optimizer": "Adam", "epochs": max_epochs, "lr": optimizer.param_groups[0]["lr"]})
        log(f"mlflow tracking to {tracking_uri}")
        return ctx
    except Exception as e:  # noqa: BLE001 — tracking is best-effort, never fatal
        log(f"mlflow init failed, continuing without tracking: {e}")
        return None


def load_train_objs():
    transform = transforms.Compose([transforms.ToTensor(), transforms.Normalize((0.1307,), (0.3081,))])
    # Shared filesystem: rank 0 downloads MNIST once, the rest wait then read the same copy.
    if rank == 0:
        log(f"downloading MNIST to {DATA_DIR}")
        datasets.MNIST(root=DATA_DIR, train=True, download=True)
    if dist.is_initialized():
        dist.barrier()
    train_set = datasets.MNIST(root=DATA_DIR, train=True, download=False, transform=transform)
    model = MLP()
    optimizer = torch.optim.Adam(model.parameters(), lr=1e-3)
    return train_set, model, optimizer


def main():
    ddp_setup()
    dataset, model, optimizer = load_train_objs()
    train_data = DataLoader(
        dataset,
        batch_size=BATCH_SIZE,
        pin_memory=use_cuda,
        shuffle=False,
        sampler=DistributedSampler(dataset),
    )
    trainer = Trainer(model, train_data, optimizer, SAVE_EVERY, SNAPSHOT_PATH)
    log(f"starting training: {TOTAL_EPOCHS} epochs, batch_size {BATCH_SIZE}")
    trainer.train(TOTAL_EPOCHS, USE_MLFLOW, TRACKING_URI)
    # Barrier before teardown so rank 0's final snapshot write completes before any rank exits
    # and tears the process group down under it (would surface as a gloo/NCCL connection reset).
    dist.barrier()
    destroy_process_group()
    log("done")


if __name__ == "__main__":
    main()
