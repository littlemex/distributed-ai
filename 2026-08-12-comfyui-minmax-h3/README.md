# ComfyUI + MiniMax-H3 on EKS (us-west-2, single L40S)

Generate video — with synchronized audio — using **MiniMax-H3** in **ComfyUI**, on a single
NVIDIA L40S GPU in Amazon EKS. The cluster is provisioned from the reusable
[`../infra/eks`](../infra/eks) module; this project is a thin layer on top that adds one GPU
node pool, shared storage for the model weights, and the ComfyUI workload itself.

MiniMax-H3 is a 33B-parameter open-weight model that jointly generates video and native stereo
audio in a single forward pass. Despite its size it runs on one **L40S (48 GB VRAM)** because
ComfyUI loads its components sequentially with CPU offload (text encoder, then the diffusion
transformer, then the VAEs), so no single stage has to fit in VRAM all at once.

> **This project reuses `infra/eks` as a child module — it never copies or edits it.** Its
> Terraform state is isolated in [`terraform/`](terraform/), so the pre-existing `us-east-2`
> cluster is never touched.

This has been verified end to end on real hardware (us-west-2): `terraform apply` → in-cluster
image build → 40 GB weight fetch → ComfyUI up → an 864×480 / ~5 s H.264 clip with AAC audio,
generated in about 4 minutes once the model is resident.

---

## How it fits together

```
                        Amazon EKS (us-west-2)
                        │
  terraform apply ──────┤  module "cluster" { source = "../../infra/eks" }
                        │    ├─ Karpenter GPU pool "comfyui"  → g6e.2xlarge / g6e.4xlarge (L40S)
                        │    ├─ FSx for OpenZFS  → /shared (model weights + outputs, single-AZ NFS)
                        │    └─ in-cluster BuildKit builder (ECR + Pod Identity)
                        │
  charts/comfyui  ──────┤  1. image-build-comfyui  → build the ComfyUI image, push to ECR
  (helm template |      │  2. model-fetch          → download the 4 MiniMax-H3 files to /shared
   kubectl apply)       │  3. comfyui              → Deployment (1× L40S) + ClusterIP Service
                        │
  kubectl port-forward ─┘  → http://localhost:8188  (Web UI, and the /prompt API)
```

Everything runs inside the cluster: there is no local Docker/finch (the image is built by a
rootless BuildKit Job), and the model weights live on shared storage rather than baked into the
image, so a pod restart re-mounts them instead of re-downloading 40 GB.

---

## Key design decisions

| Decision | Why |
|---|---|
| **L40S (g6e), On-Demand, protected from disruption** | The ~40 GB of pre-quantized weights fit a 48 GB L40S via ComfyUI's sequential offload; 24 GB cards (g6/g5) are unreliable for a 33B video model, so they are deliberately excluded from the serving pool. ComfyUI is a **stateful single pod** with an in-memory queue, so a Spot reclaim would lose an in-flight generation — hence On-Demand, `karpenter.sh/do-not-disrupt`, a `protect` disruption preset, and a `Recreate` rollout strategy. |
| **No public endpoint** | ComfyUI ships no authentication and its Web UI can install custom nodes, i.e. execute arbitrary Python — exposing it publicly is effectively an open RCE. Access is `kubectl port-forward` only; the base module's CloudFront/ALB demo path stays off. |
| **Native ComfyUI H3 support (no third-party nodes)** | ComfyUI core supports MiniMax-H3 using Comfy-Org's pre-packaged, pre-quantized weights — no fragile GGUF/wrapper custom nodes. The image bakes ComfyUI at a pinned ref (v0.31.1) on a pinned torch stack (2.8.0 + CUDA 12.6). |
| **FSx for OpenZFS for weights + outputs** | Single-AZ NFS, co-located in one AZ with the GPU pool, so there is no cross-AZ data-transfer cost. FSx Lustre is off — a single node needs no parallel scratch filesystem. Weights are fetched once and survive pod restarts. |
| **Reproducibility is pinned, everything else is a variable** | Region, account, instance types, and the model repo/revision are all inputs with sane defaults. Versions that must not drift — ComfyUI, torch, the model revision, the workflow-template commit, the container image tag — are pinned. |

---

## Repository layout

```
2026-08-12-comfyui-minmax-h3/
├── terraform/            Thin root module. Sources ../../infra/eks, defines the ComfyUI GPU
│                         pool + OpenZFS storage, and creates the ComfyUI ECR repo (whose ARN
│                         it hands to the builder). Its own isolated Terraform state.
├── image/comfyui/        Dockerfile for the ComfyUI runtime — pinned ComfyUI + torch, no pip
│                         at startup, model weights NOT baked in.
├── charts/comfyui/       Helm chart with three independently-toggled workloads:
│                         image build (BuildKit → ECR), model fetch, and the ComfyUI Deployment.
├── workflows/            The runnable API-format T2V workflow, plus the pinned official
│                         UI-format templates for reference. See workflows/README.md.
└── scripts/              up.sh (one-shot bring-up), port-forward.sh, run_smoke.py.
```

---

## Quick start

### One-shot: `scripts/up.sh`

`scripts/up.sh` runs the entire bring-up in order and is idempotent — safe to re-run after a
partial failure. It provisions the cluster, builds the ComfyUI image in-cluster, fetches the
~40 GB of weights, deploys ComfyUI, and finally port-forwards the Web UI. It never changes
your active kubectl context (every call uses `--context`), and FSx Lustre is off by default.

```bash
cd 2026-08-12-comfyui-minmax-h3
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # set region / account / profile
./scripts/up.sh                     # full bring-up, ends by forwarding http://localhost:8188
```

Useful variants:

```bash
./scripts/up.sh --no-forward        # do everything except the final port-forward
IMAGE_TAG=v3 ./scripts/up.sh        # build/deploy a specific image tag (default: v2)
FSX_LUSTRE=true ./scripts/up.sh     # also create the FSx Lustre scratch filesystem
AWS_PROFILE=my-profile ./scripts/up.sh
```

The script reads every name (cluster, ECR repo, GPU pool, storage PV) from `terraform output`,
skips the image build if the tag is already in ECR, and derives the build's git ref from the
current pushed branch. First run is ~30 min end to end (control plane ~15 min, image build
~8 min, weight fetch ~8 min); re-runs are much faster.

### Step by step

To run one stage at a time — or to see the exact `helm template ... --set` flags and `kubectl`
commands each step uses — read **[`scripts/up.sh`](scripts/up.sh)**. It is written to be read: the
six numbered steps (terraform apply → in-cluster image build → shared PVC → weight fetch →
deploy → port-forward) each carry the full command, so you can copy any single stage out of it.
Generation once the UI is up:

```bash
./scripts/port-forward.sh                          # → http://localhost:8188
python3 scripts/run_smoke.py workflows/video_minimax_h3_t2v.api.json \
  --out ./out --prompt "your scene + audio description" --prompt-node 104
```

---

## Generating a video

Two ways, both against the same running ComfyUI:

- **Web UI** — open http://localhost:8188 (via `scripts/port-forward.sh`), load a workflow,
  edit the prompt, and click Run.
- **Headless** — `scripts/run_smoke.py` posts an API-format workflow to `/prompt`, polls
  `/history`, and downloads the result:

  ```bash
  python3 scripts/run_smoke.py workflows/video_minimax_h3_t2v.api.json \
    --out ./out \
    --prompt "Anime-style creature battle, electric vs fire, dynamic camera. \
              Audio: energetic orchestral score with thunder and flame SFX." \
    --prompt-node 104 --seed 77
  ```

Prompt tips for MiniMax-H3: describe the visuals **and** the audio (dialogue, SFX, music) in one
block, since audio is generated jointly. Resolution and length are inlined in the workflow
(864×480, `length=124` ≈ 5 s on the model's 17k+5 frame grid); edit node `104` to change them.
See [workflows/README.md](workflows/README.md) for how the API workflow was built and how to
produce one for image-to-video / reference-to-video.

---

## Generating images (Qwen-Image)

The same cluster also serves still-image work with the Qwen-Image family: Qwen-Image 2512 for text to image and Qwen-Image-Edit 2511 for edits that take up to three reference images, which keeps one character consistent across many pictures. Both are Apache-2.0, run as fp8 checkpoints with the Lightning LoRA merged in (4 steps), and need only ComfyUI core nodes. The image also bakes a small in-repo node, `BiRefNetRemoveBackground` (`image/comfyui/custom_nodes/birefnet_rmbg`, BiRefNet under MIT), so a workflow can cut a figure out of its background and save a transparent PNG.

```bash
helm template comfyui ./charts/comfyui -n comfyui -f charts/comfyui/presets/qwen-image.yaml \
  -s templates/model-fetch.yaml --set modelFetch.enabled=true --set comfyui.image="$ECR_URL:v3" | kubectl apply -f -
helm template comfyui ./charts/comfyui -n comfyui -f charts/comfyui/presets/qwen-image.yaml \
  -s templates/comfyui.yaml --set comfyui.enabled=true --set comfyui.image="$ECR_URL:v3" \
  --set comfyui.nodeRole="$POOL" | kubectl apply -f -

python3 scripts/run_smoke.py workflows/image_qwen_t2i_cutout.api.json --out ./out --prompt-node 6 \
  --prompt "a cute paper lantern spirit, glossy 3D collectible figure, full body, plain white background"
python3 scripts/run_smoke.py workflows/image_qwen_edit_cutout.api.json --out ./out --prompt-node 6 \
  --input-image ./out/cutout_00001_.png --prompt "The same character, waving happily, plain white background"
```

The preset fetches about 51 GB into `qwen/models` on the shared volume. `modelSets` in a values file lists any number of Hugging Face repos for the model-fetch Job; without it the Job fetches the MiniMax-H3 set as before.

| Measured on one L40S (g6e.4xlarge) | Time |
|---|---|
| Warm text to image, 1.3 MP, 4 steps | 7 to 10 s |
| Warm edit with one reference | 16 to 21 s |
| First use of a checkpoint (20 GB read from OpenZFS) | 4 to 6 min |
| Switching between the two checkpoints afterwards | about 20 s |

The switch time depends on `--disable-dynamic-vram --disable-mmap` (set in the preset); with ComfyUI's defaults each switch re-read the checkpoint over NFS and took about 4 minutes. Put work for the same checkpoint together.

### On a desktop GPU (for example an RTX 4090)

The same image and weights run on a single 24 GB card. Qwen-Image's fp8 checkpoint (20 GB) plus its text encoder (9 GB) do not fit in 24 GB at once; ComfyUI loads the text encoder, encodes, then swaps in the diffusion model, so plan on 64 GB of system RAM and keep one checkpoint per session where you can.

```bash
docker build -t comfyui-qwen image/comfyui
uv run scripts/fetch_models_local.py charts/comfyui/presets/qwen-image.yaml ~/comfyui/models
docker run --rm --gpus all -p 8188:8188 \
  -v ~/comfyui/models:/opt/ComfyUI/models -v ~/comfyui/output:/opt/ComfyUI/output \
  comfyui-qwen --disable-dynamic-vram --disable-mmap
```

`scripts/fetch_models_local.py` reads the preset's `modelSets`, so a home machine and the cluster use identical files. `scripts/run_smoke.py` and the workflows above work unchanged against `http://localhost:8188`.

## Cost

The EKS control plane, NAT gateways, system nodes, and the OpenZFS filesystem bill
continuously; the g6e GPU node bills per hour while it is running. To pause spend without
tearing everything down, delete the workload and let Karpenter reclaim the GPU node (the
weights remain on OpenZFS):

```bash
kubectl -n comfyui delete deploy comfyui        # GPU node consolidates away in a few minutes
```

To remove everything (cluster, GPU node, FSx, ECR):

```bash
cd terraform && terraform destroy
```

The base module's README **Cost** and **Known limitations** sections apply in full — in
particular, `terraform destroy` drains the GPU node first and can take ~10 minutes. Delete the
Deployment before destroy (`kubectl -n comfyui delete deploy comfyui`) so the `do-not-disrupt`
pod cannot stall it.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `kubectl` → `Unauthorized` | kubectl runs as a different principal than the applying one. Re-run `aws eks update-kubeconfig` with the same `--profile`; confirm with `aws sts get-caller-identity`. |
| ComfyUI pod stuck `Pending` | GPU node still launching (`kubectl get nodeclaims`), or `comfyui.memory` exceeds the node's allocatable — lower it, or add a larger `gpu_instance_types` entry. |
| Pod OOM / CUDA OOM on first generation | The 48 GB path is tight with the text encoder + VAE decode. Add `--set comfyui.extraArgs="--lowvram"`, or use `g6e.4xlarge` (more host RAM for offload). |
| Pod `CrashLoopBackOff` at startup | Almost always torch too old for ComfyUI v0.31 (`unsupported type list[int]` at import). Use image tag `v2`+ (torch 2.8.0 / CUDA 12.6); do not downgrade torch below 2.7. |
| model-fetch slow / HF 429 | Rerun — it is idempotent and resumes. It sets `HF_HUB_DISABLE_XET=1`; for a private repo set `modelFetch.hfTokenSecretName`. |
| `/prompt` rejects the workflow | You posted a UI-format template. Use the committed `workflows/video_minimax_h3_t2v.api.json`, or export API format from the Web UI. See [workflows/README.md](workflows/README.md). |
| Generated video has no audio | Confirm both VAEs were fetched (`vae/minimax_h3_audio_vae_fp32.safetensors`) and the workflow's audio branch is intact. |

---

> Sample/reference code, not an official AWS project. Review and harden before any production
> use. ComfyUI's Web UI is unauthenticated by design here — keep it behind `port-forward`.
