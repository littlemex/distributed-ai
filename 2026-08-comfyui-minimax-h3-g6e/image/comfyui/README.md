# ComfyUI image (MiniMax-H3, single-L40S)

A minimal, reproducible ComfyUI runtime baked at a pinned ref. Model weights are
**not** baked in — they live on the shared filesystem and are fetched once by the
workload's init container (see `../../charts/comfyui`).

## What is baked in

| Layer | Default | Build ARG |
|---|---|---|
| CUDA base | `nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04` | `CUDA_IMAGE` |
| ComfyUI | `v0.31.0` (has native MiniMax-H3 support) | `COMFYUI_REF` |
| PyTorch wheels | cu124 index | `TORCH_INDEX` |
| ComfyUI-Manager | `3.28` (optional) | `COMFYUI_MANAGER_REF`, `COMFYUI_MANAGER` |

MiniMax-H3 (T2V/I2V/R2V) is supported by **ComfyUI core** — no third-party GGUF or
wrapper custom node is required, which is why the image bakes in only ComfyUI-Manager
(for interactive inspection, and even that is optional).

## How it is built

In-cluster with rootless BuildKit (no local docker/finch), pushed to the ComfyUI ECR
repo. See `../../charts/comfyui/templates/image-build-comfyui.yaml` and the runbook in
`../../docs/GETTING_STARTED.md`. To build a different ComfyUI version, bump the tag and
pass `--set imageBuild.buildArgs.COMFYUI_REF=<tag>` — do not edit the Dockerfile.

## Why weights are not in the image

The four MiniMax-H3 files total ~40 GB. Baking them in would make a ~45 GB image that
is slow to pull on every Pod start and re-pushed on every code change. On the shared
filesystem they are fetched once and survive Pod restarts / reschedules.
