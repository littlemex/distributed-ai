# hf-train-sample
#
# A minimal HuggingFace Trainer image for the distributed-training examples in this repo.
# It is launched by `torchrun` — directly (single-node torchrun Job) or under a Kubeflow
# PyTorchJob, whose training-operator injects MASTER_ADDR / MASTER_PORT / WORLD_SIZE / RANK
# into every pod and lets torchrun turn them into --nnodes / --node_rank / --master_addr /
# --master_port. Because rendezvous is handled entirely by torch.distributed's c10d env://
# backend, this image needs no sshd, no Open MPI, and no OMPI_*→torch.distributed shim: it is
# just the PyTorch runtime + the HF Trainer stack + the training script.
FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

RUN pip install --no-cache-dir \
      'transformers==4.46.3' \
      'datasets==3.1.0' \
      'accelerate==1.1.1'

COPY train_smollm.py /workspace/train_smollm.py
WORKDIR /workspace
