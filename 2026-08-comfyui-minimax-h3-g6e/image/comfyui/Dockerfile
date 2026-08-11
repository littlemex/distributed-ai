# ComfyUI image for MiniMax-H3 video generation on a single NVIDIA L40S (g6e).
#
# Design (per the review):
#   * ComfyUI and every dependency are BAKED IN at a pinned ref — nothing is
#     pip-installed at Pod startup. Startup pip is non-reproducible, slow, and dies
#     when PyPI hiccups; a workshop that "installs on boot" is not a workshop.
#   * MiniMax-H3 is supported by ComfyUI core (no third-party GGUF/wrapper node), so
#     the only custom node baked in is ComfyUI-Manager for interactive inspection —
#     and even that is optional (COMFYUI_MANAGER=false to omit it). No custom node is
#     required for the T2V/I2V/R2V workflows themselves.
#   * Model WEIGHTS are NOT baked in (they are ~40 GB and belong on the shared
#     filesystem, fetched once by the workload's init container). This image is just
#     the runtime; it stays ~small and rebuilds fast.
#
# Base: NVIDIA's CUDA runtime image, so the L40S driver in the g6e AL2023 GPU AMI is
# matched by a userspace CUDA that PyTorch's cu124 wheels expect. We install a CPU-less
# slim Python layer on top and let ComfyUI pull the correct torch wheel.
#
# Everything version-bearing is a build ARG so the image is reproducible AND bumpable
# from the build Job without editing this file.

ARG CUDA_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu22.04
FROM ${CUDA_IMAGE}

# ── Versions (all overridable at build time) ────────────────────────────────────
# COMFYUI_REF  : git tag/sha of ComfyUI to bake in. Pin a RELEASE for reproducibility.
# TORCH_INDEX  : the PyTorch wheel index matching the CUDA base (cu126 for 12.6).
# TORCH_*      : pinned torch stack. ComfyUI's requirements.txt lists a BARE `torch` (no
#                version), so without these pins the build would drift between rebuilds.
#                MUST be torch >= 2.7: ComfyUI v0.31's native comfy_kitchen ops annotate
#                torch.library custom ops with PEP 585 builtin generics (list[int]), which
#                torch <= 2.6's infer_schema rejects with "unsupported type list[int]" at
#                import (verified live on 2.6.0+cu124 — ComfyUI crashed on startup). torch
#                2.8.0 needs a CUDA >= 12.6 wheel index, hence the cu126 base above. The L40S
#                node's driver (AL2023 GPU AMI, 570+) is CUDA 12.6/12.8-capable.
# COMFYUI_MANAGER: bake in ComfyUI-Manager (interactive node management) — optional.
# All refs verified to exist (git ls-remote / the cu126 wheel index) as of 2026-08.
ARG COMFYUI_REF=v0.31.1
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu126
ARG TORCH_VERSION=2.8.0
ARG TORCHVISION_VERSION=0.23.0
ARG TORCHAUDIO_VERSION=2.8.0
ARG COMFYUI_MANAGER_REF=4.2.2
ARG COMFYUI_MANAGER=true

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# System deps: python, git (to clone ComfyUI at a pinned ref), ffmpeg (ComfyUI encodes
# the generated frames+audio into a video file), and libs the video/image nodes need.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv git ffmpeg \
        libgl1 libglib2.0-0 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3 /usr/bin/python

WORKDIR /opt

# ── ComfyUI at a pinned ref ──────────────────────────────────────────────────────
# Clone then checkout the exact ref (a tag or full sha). Shallow-fetching a specific
# sha needs the two-step form; a tag works with --branch, so handle both.
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI \
    && cd /opt/ComfyUI \
    && git checkout "${COMFYUI_REF}" \
    && git rev-parse HEAD > /opt/ComfyUI/.baked_ref

WORKDIR /opt/ComfyUI

# PyTorch first (PINNED, from the CUDA-matched index), then ComfyUI's own requirements.
# Splitting the layers keeps the big torch download cached across ComfyUI requirement bumps.
# The +<cuda> local version tag is DERIVED from the last path segment of TORCH_INDEX (e.g.
# cu126), so the wheel's CUDA suffix can never drift from the index it is pulled from.
ARG HF_HUB_VERSION=0.34.4
RUN python -m pip install --upgrade pip \
    && CUDA_TAG="$(basename "${TORCH_INDEX}")" \
    && python -m pip install \
        "torch==${TORCH_VERSION}+${CUDA_TAG}" \
        "torchvision==${TORCHVISION_VERSION}+${CUDA_TAG}" \
        "torchaudio==${TORCHAUDIO_VERSION}+${CUDA_TAG}" \
        --index-url "${TORCH_INDEX}" \
    && python -m pip install -r requirements.txt \
    # huggingface_hub[hf_transfer] is baked in so the model-fetch Job can reuse THIS image
    # instead of pip-installing the hub at runtime (same no-startup-pip discipline as ComfyUI).
    && python -m pip install "huggingface_hub[hf_transfer]==${HF_HUB_VERSION}"

# ── Optional: ComfyUI-Manager (interactive node/model management in the Web UI) ──
# Baked at a pinned ref, not installed at boot. Omit with --build-arg COMFYUI_MANAGER=false.
RUN if [ "${COMFYUI_MANAGER}" = "true" ]; then \
        git clone https://github.com/ltdrdata/ComfyUI-Manager.git \
            /opt/ComfyUI/custom_nodes/ComfyUI-Manager \
        && cd /opt/ComfyUI/custom_nodes/ComfyUI-Manager \
        && git checkout "${COMFYUI_MANAGER_REF}" \
        && python -m pip install -r requirements.txt ; \
    fi

# ── Model / IO directories ───────────────────────────────────────────────────────
# ComfyUI reads weights from /opt/ComfyUI/models/{diffusion_models,text_encoders,vae,...}
# and writes to /opt/ComfyUI/output. The workload (charts/comfyui) mounts the shared
# filesystem OVER these paths directly (volumeMounts with subPath) — NOT via an
# extra_model_paths.yaml — so weights and outputs persist across Pod restarts and are
# fetched once. We just create the base tree here so the image stays storage-agnostic;
# the Deployment overlays the mounts. input/ and user/ are also mount candidates when
# running I2V (input images) or persisting saved workflows.
RUN mkdir -p /opt/ComfyUI/models /opt/ComfyUI/output /opt/ComfyUI/input /opt/ComfyUI/user

EXPOSE 8188

# ComfyUI listens on 0.0.0.0 so the Service/port-forward can reach it. The Deployment
# mounts the shared volume over models/ and output/ directly (no --output-directory flag
# needed — the default path IS the mount), and may append flags (e.g. --lowvram) via
# comfyui.extraArgs. We do NOT pin --lowvram/--normalvram here: ComfyUI auto-detects VRAM
# and picks the offload strategy.
ENTRYPOINT ["python", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
