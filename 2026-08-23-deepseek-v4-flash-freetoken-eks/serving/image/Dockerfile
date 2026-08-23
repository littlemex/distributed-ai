# FreeToken serving image.
#
# Why a -devel base and not -runtime: FreeToken ships its CUDA kernels as JIT sources and
# compiles them on first use, so `nvcc` must exist at RUN TIME, not just at build time. That also
# means the FIRST request on a cold pod pays the compile unless the kernel cache is warm -- see
# the kernel-cache step below.
#
# Driver contract: the CUDA toolkit minor version here must be <= what the node's driver supports
# (CUDA 13.0 needs >= 580.65.06; the EKS AL2023 NVIDIA AMI ships 580.178.04). image.env explains
# why this is pinned to 13.0.x rather than the newest 13.x.
ARG BASE_IMAGE=nvidia/cuda:13.0.3-devel-ubuntu24.04
FROM ${BASE_IMAGE}

ARG FREETOKEN_REPO=https://github.com/FlashML-org/FreeToken.git
ARG FREETOKEN_REF=main
ARG TORCH_SPEC=torch>=2.11,<2.12

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/cuda/bin:/opt/venv/bin:$PATH \
    CUDA_HOME=/usr/local/cuda \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/hf-cache

# Ubuntu 24.04 carries python3.12, which clears FreeToken's ">= 3.10" floor. git is needed for the
# source install; ca-certificates for the HF download path.
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-venv python3-dev git ca-certificates curl build-essential \
    && rm -rf /var/lib/apt/lists/*

# uv is FreeToken's recommended installer and resolves the accel extras far faster than pip.
RUN curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

RUN python3 -m venv /opt/venv
# torch first and on its own: the accel extras build against the installed torch, so letting the
# resolver pick torch in the same pass can select a wheel the extension build then disagrees with.
RUN uv pip install --python /opt/venv/bin/python "${TORCH_SPEC}" ninja

WORKDIR /opt
RUN git clone --filter=blob:none "${FREETOKEN_REPO}" freetoken \
    && cd freetoken \
    && git checkout "${FREETOKEN_REF}" \
    && git rev-parse HEAD > /opt/freetoken-commit.txt

# --no-build-isolation so the CUDA extension (freetoken.kernel._pinned_tensor, which is what
# performs the cudaHostRegister that page-locks the expert banks) builds against the torch above.
RUN cd /opt/freetoken \
    && uv pip install --python /opt/venv/bin/python -e ".[accel]" --no-build-isolation

# Bake the upstream kernel cache so a cold pod does not JIT on its first request. The repo ships
# freetoken-kernel-cache/ for exactly this; if that path ever disappears upstream this step is a
# no-op rather than a build failure, and the only cost is a slower first token.
ENV FREETOKEN_KERNEL_CACHE=/opt/freetoken-kernel-cache
RUN if [ -d /opt/freetoken/freetoken-kernel-cache ]; then \
      cp -r /opt/freetoken/freetoken-kernel-cache "${FREETOKEN_KERNEL_CACHE}"; \
    else \
      mkdir -p "${FREETOKEN_KERNEL_CACHE}"; \
    fi

# Record what we built so a running pod can be traced back to a commit without guessing.
RUN /opt/venv/bin/python -c "import freetoken, torch; print('freetoken', getattr(freetoken,'__version__','?'), 'torch', torch.__version__)" \
      > /opt/freetoken-build.txt 2>&1 || true

EXPOSE 1919
ENTRYPOINT ["/opt/venv/bin/ft"]
CMD ["--help"]
