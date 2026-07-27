# ddp-sample
#
# A minimal DistributedDataParallel image for the distributed-training examples in this repo.
# It trains an MNIST MLP under `torch.distributed` — launched by `torchrun` directly (single-
# node torchrun Job) or under a Kubeflow PyTorchJob, whose training-operator + spec.elasticPolicy
# make torchrun perform the c10d rendezvous and export RANK / WORLD_SIZE / LOCAL_RANK /
# MASTER_ADDR / MASTER_PORT into every training process. Because rendezvous is handled entirely
# by torch.distributed's c10d env:// backend, this image needs no sshd, no Open MPI, and no
# etcd — it is just the PyTorch runtime plus the training script.
#
# torch AND torchvision both ship in the pytorch/pytorch base image, and MNIST + the MLP need
# nothing else, so there is not a single extra pip layer. mlflow is intentionally omitted:
# ddp.py imports it lazily and only when USE_MLFLOW=1, degrading to no-tracking otherwise.
FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

COPY ddp.py /workspace/ddp.py
WORKDIR /workspace
