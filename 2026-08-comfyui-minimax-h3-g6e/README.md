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
> cluster is never touched. The design invariants are documented in
> [docs/PROJECT_RULES.md](docs/PROJECT_RULES.md).

This has been verified end to end on real hardware (us-west-2): `terraform apply` → in-cluster
image build → 40 GB weight fetch → ComfyUI up → an 864×480 / ~5 s H.264 clip with AAC audio,
generated in about 4 minutes once the model is resident. See
[docs/PROJECT_STATUS.md](docs/PROJECT_STATUS.md) for the full verification log.

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
2026-08-comfyui-minimax-h3-g6e/
├── terraform/            Thin root module. Sources ../../infra/eks, defines the ComfyUI GPU
│                         pool + OpenZFS storage, and creates the ComfyUI ECR repo (whose ARN
│                         it hands to the builder). Its own isolated Terraform state.
├── image/comfyui/        Dockerfile for the ComfyUI runtime — pinned ComfyUI + torch, no pip
│                         at startup, model weights NOT baked in.
├── charts/comfyui/       Helm chart with three independently-toggled workloads:
│                         image build (BuildKit → ECR), model fetch, and the ComfyUI Deployment.
├── workflows/            The runnable API-format T2V workflow, plus the pinned official
│                         UI-format templates for reference. See workflows/README.md.
├── scripts/              port-forward.sh and run_smoke.py (submit a workflow, poll, download).
└── docs/                 GETTING_STARTED (the full runbook), PROJECT_STATUS, PROJECT_RULES.
```

---

## Quick start

The complete, copy-paste runbook — including every `--set` flag and the troubleshooting table —
is in **[docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)**. The shape of it:

```bash
# 1. Provision the cluster (~15 min: control plane, GPU pool, OpenZFS, ECR).
cd terraform
cp terraform.tfvars.example terraform.tfvars     # set aws_profile / expected_account_id
terraform init && terraform apply
aws eks update-kubeconfig --name "$(terraform output -raw cluster_name)" \
  --region "$(terraform output -raw region)" --profile <same-as-tfvars>

# 2. Build the ComfyUI image in-cluster, then fetch the weights, then deploy.
#    (Exact commands + the required --set flags are in the runbook.)

# 3. Open the UI and generate a clip.
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
particular, `terraform destroy` drains the GPU node first and can take ~10 minutes, and the
runbook deletes the Deployment before destroy so the `do-not-disrupt` pod cannot stall it.

---

> Sample/reference code, not an official AWS project. Review and harden before any production
> use. ComfyUI's Web UI is unauthenticated by design here — keep it behind `port-forward`.
