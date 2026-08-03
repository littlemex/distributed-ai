# ddp-sample
#
# A minimal DistributedDataParallel image for the distributed-training examples in this repo.
# It trains an MNIST MLP under `torch.distributed` — launched by `torchrun` directly (single-
# node torchrun Job) or under a Kubeflow Trainer v2 TrainJob, whose torch plugin points torchrun
# at node-0 for c10d rendezvous (no self-hosted etcd Service) and injects PET_NNODES /
# PET_NPROC_PER_NODE / PET_MASTER_ADDR etc. torchrun then exports RANK / WORLD_SIZE / LOCAL_RANK /
# MASTER_ADDR / MASTER_PORT into every training process, which is where ddp.py reads them.
# Because rendezvous is handled entirely by torch.distributed's c10d env:// backend, this image
# needs no sshd, no Open MPI, and no etcd — it is just the PyTorch runtime plus the training
# script. (A v1-era self-hosted etcd rendezvous store used to live behind this image, which is
# why an earlier revision installed python-etcd here; ddp.py has never imported it.)
#
# torch AND torchvision both ship in the pytorch/pytorch base image, and MNIST + the MLP need
# nothing else, so there is not a single pip layer. mlflow is intentionally omitted: ddp.py
# imports it lazily and only when USE_MLFLOW=1, degrading to no-tracking otherwise.
FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

COPY ddp.py /workspace/ddp.py
WORKDIR /workspace
