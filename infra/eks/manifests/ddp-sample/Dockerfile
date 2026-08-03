# ddp-sample
#
# A minimal DistributedDataParallel image for the distributed-training examples in this repo.
# It trains an MNIST MLP under `torch.distributed` — launched by `torchrun` directly (single-
# node torchrun Job) or under a Kubeflow Trainer v2 TrainJob (trainer.kubeflow.org/v1alpha1),
# whose torch plugin injects PET_NNODES / PET_NPROC_PER_NODE / PET_NODE_RANK / PET_MASTER_ADDR /
# PET_MASTER_PORT and lets torchrun read them as CLI defaults, performing the c10d rendezvous.
# Because rendezvous is handled entirely by torch.distributed's c10d env:// backend, this image
# needs no sshd, no Open MPI, and no etcd — it is just the PyTorch runtime plus the training
# script. (v1 PyTorchJob used a self-hosted etcd rendezvous store; Trainer v2 replaced it with
# the runtimeRef + PET_* mechanism above, so an etcd client has had nothing to talk to since.)
#
# torch AND torchvision both ship in the pytorch/pytorch base image, and MNIST + the MLP need
# nothing else, so there is not a single extra pip layer. mlflow is intentionally omitted:
# ddp.py imports it lazily and only when USE_MLFLOW=1, degrading to no-tracking otherwise.
FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

COPY ddp.py /workspace/ddp.py
WORKDIR /workspace
