# ComfyUI + MiniMax-H3 on EKS (us-west-2, single L40S)

Generate a video with **MiniMax-H3** (a 33B open-weight image/text-to-video + audio model)
in **ComfyUI**, running on a fresh EKS cluster in `us-west-2` provisioned from the reusable
`../infra/eks` module. A single **g6e.2xlarge** (NVIDIA L40S, 48 GB VRAM) hosts the model;
you reach the ComfyUI Web UI over `kubectl port-forward` and drive a text-to-video generation
end to end.

> This project **reuses** the `infra/eks` module as a child module — it does not copy or modify
> it. Its Terraform state is isolated in `terraform/`, so the existing `us-east-2` cluster is
> never touched. See [docs/PROJECT_RULES.md](docs/PROJECT_RULES.md) for the design invariants.

## Why these choices

| Decision | Reason |
|---|---|
| **g6e (L40S 48 GB), On-Demand only** | MiniMax-H3's ~40 GB of pre-quantized weights fit 48 GB via ComfyUI's sequential offload; 24 GB cards (g6/g5) are unreliable for a 33B video model. ComfyUI is a **stateful single pod** (in-memory queue), so Spot reclaim would lose an in-flight generation — On-Demand + `do-not-disrupt` + `Recreate` protect it. |
| **No public endpoint** | ComfyUI has no auth and its Web UI can execute arbitrary Python (custom nodes) — publishing it is effectively an open RCE. Access is `kubectl port-forward` only; the base module's CloudFront/ALB path stays off. |
| **Native ComfyUI H3 support** | ComfyUI core supports MiniMax-H3 with Comfy-Org pre-packaged, pre-quantized weights — no fragile third-party GGUF/wrapper nodes. The image bakes ComfyUI at a pinned ref; weights are fetched once to shared storage. |
| **FSx OpenZFS for weights + outputs** | Single-AZ NFS, co-located with the GPU pool (no cross-AZ cost). FSx Lustre is off (no parallel scratch needed for one node). Weights survive pod restarts and are downloaded once. |

## Layout

```
2026-08-comfyui-minimax-h3-g6e/
├── terraform/            Thin root module: sources ../../infra/eks, adds the ComfyUI GPU pool,
│                         OpenZFS storage, and a ComfyUI ECR repo + build IAM. Isolated state.
├── image/comfyui/        Dockerfile for the ComfyUI runtime (pinned ComfyUI, no startup pip).
├── charts/comfyui/       Helm chart: in-cluster image build · model fetch · ComfyUI Deployment.
├── workflows/            Pinned official MiniMax-H3 T2V/I2V templates + format notes.
├── scripts/              port-forward.sh · run_smoke.py (submit workflow, poll, download video).
└── docs/                 GETTING_STARTED (the runbook) · PROJECT_STATUS · PROJECT_RULES.
```

## Quick start

The full, copy-paste runbook is **[docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)**. In brief:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set aws_profile / expected_account_id
terraform init && terraform apply              # ~15 min: cluster + GPU pool + OpenZFS + ECR

# then, from the repo dir (see the runbook for the exact --set flags):
#   1. build the ComfyUI image in-cluster (BuildKit → ECR)
#   2. create the shared PVC, fetch the MiniMax-H3 weights to it
#   3. deploy ComfyUI, port-forward, and run scripts/run_smoke.py for one video
```

## Cost note

The EKS control plane, NAT, system nodes, and the OpenZFS filesystem bill continuously; the
g6e GPU node bills per hour while running. Run `terraform destroy` when done. See the base
module's README **Cost** section — everything there applies.
