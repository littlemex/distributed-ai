# Getting Started: ComfyUI + MiniMax-H3 on EKS

**最終更新**: 2026-08-10
**対象者**: このクラスタを初めて立てる人

A task-oriented runbook: from zero to one generated video. Every command is copy-paste ready;
replace `<angle-bracket>` placeholders. Nothing here contains an account ID, IP, or cluster
name — you set those in `terraform.tfvars`.

## What you are building

```
Client (kubectl port-forward)
        │  http://localhost:8188
        ▼
ComfyUI pod  ── nvidia.com/gpu:1 ──►  g6e.2xlarge (L40S 48GB)   [node-role=comfyui, On-Demand]
   │  reads weights / writes outputs
   ▼
FSx OpenZFS (single-AZ NFS, /shared)  ◄── model-fetch Job downloads ~40GB MiniMax-H3 weights once
```

The ComfyUI image is built in-cluster (BuildKit → ECR); the cluster, GPU pool, storage, and the
ECR repo all come from `terraform apply`.

## 0. Prerequisites

Terraform 1.9+, AWS CLI 2.15+, kubectl 1.29+, helm 3.14+, and credentials for the target
account. Confirm you are pointed at the right account **before** creating anything:

```bash
aws sts get-caller-identity          # is this the account (and region intent) you meant?
```

## 1. Provision the cluster

```bash
cd 2026-08-comfyui-minimax-h3-g6e/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set aws_profile (if you use a named/SSO profile) and, strongly
# recommended, expected_account_id. Defaults already target us-west-2 + a single-L40S pool.

terraform init
terraform apply                       # ~15 min (control plane + system nodes + GPU pool + OpenZFS + ECR)
```

Point kubectl at the new cluster. Use the **same** profile you applied with (or export
`AWS_PROFILE`), or kubectl gets `Unauthorized`:

```bash
aws eks update-kubeconfig \
  --name "$(terraform output -raw cluster_name)" \
  --region "$(terraform output -raw region)" \
  --profile <same-as-tfvars>

kubectl config current-context        # confirm it is THIS cluster before every step below
kubectl get nodes                     # system nodes; no GPU node yet (Karpenter makes it on demand)
```

Capture the outputs the rest of the runbook needs:

```bash
export ECR_URL=$(terraform output -raw comfyui_ecr_url)
export POOL=$(terraform output -raw comfyui_pool_name)          # "comfyui"
export OZFS_PV=$(terraform output -raw openzfs_persistent_volume)   # "openzfs-shared"
export NS=comfyui
echo "ECR=$ECR_URL POOL=$POOL PV=$OZFS_PV"
```

## 2. Build the ComfyUI image in-cluster

No local docker/finch: a rootless BuildKit Job builds `image/comfyui/Dockerfile` and pushes to
the ECR repo Terraform created. Run from the **project root** (the chart is at `./charts/comfyui`):

```bash
cd ..    # 2026-08-comfyui-minimax-h3-g6e/

helm template comfyui ./charts/comfyui \
  -s templates/image-build-comfyui.yaml \
  --set imageBuild.enabled=true \
  --set imageBuild.repository="$ECR_URL" \
  --set imageBuild.tag=v1 \
  --set imageBuild.gitRef="$(git rev-parse --abbrev-ref HEAD)" | kubectl apply -f -

kubectl -n image-builder wait --for=condition=complete job/build-comfyui-v1 --timeout=45m
kubectl -n image-builder logs -f job/build-comfyui-v1            # follow the build
# If the image push failed on auth, inspect the init step:
#   kubectl -n image-builder logs job/build-comfyui-v1 -c ecr-login
```

> **BuildKit fetches the Dockerfile from git, not your local checkout.** `imageBuild.gitRef`
> must be a ref that is PUSHED to `imageBuild.gitRepo` (default the branch you are on, above) —
> a local-only commit will build stale. Push first, or point gitRef at the merged branch.

> **Verified toolchain (2026-08):** the image pins ComfyUI v0.31.1 on **torch 2.8.0 + CUDA 12.6**.
> This is not optional: ComfyUI v0.31's native `comfy_kitchen` ops use PEP 585 `list[int]`
> annotations that torch <= 2.6 rejects at import (the pod CrashLoops on startup). The Dockerfile
> defaults already encode this; do not downgrade torch below 2.7.

> Rebuild a new ComfyUI version without editing the Dockerfile: bump the tag and pass the
> version as a build-arg, e.g. `--set imageBuild.tag=v2 --set imageBuild.buildArgs.COMFYUI_REF=<tag>`.

## 3. Create the shared PVC and fetch the MiniMax-H3 weights

The OpenZFS static PV is Terraform-managed; create its PVC **once** (its lifecycle matches the
data, not a workload). Use the base module's template:

```bash
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

sed "s/__VOLUME_NAME__/${OZFS_PV}/" \
  ../infra/eks/manifests/shared-pvc.yaml | kubectl apply -n "$NS" -f -
kubectl -n "$NS" get pvc shared-claim          # should become Bound
```

Fetch the four weight files (~40 GB) onto the volume. The Job reuses the ComfyUI image (which
bakes in `huggingface_hub`, so it does not pip-install at runtime), so pass the image. It is
idempotent — reruns skip files already present at the expected size, and re-fetch if a file's
size no longer matches the pinned revision:

```bash
helm template comfyui ./charts/comfyui -n "$NS" \
  -s templates/model-fetch.yaml \
  --set modelFetch.enabled=true \
  --set comfyui.image="${ECR_URL}:v1" | kubectl apply -f -

kubectl -n "$NS" wait --for=condition=complete job/comfyui-model-fetch --timeout=60m
kubectl -n "$NS" logs -f job/comfyui-model-fetch
```

> For a fully reproducible fetch, pin `minimaxH3.revision` to a commit sha instead of `main`
> (`--set minimaxH3.revision=<sha>`); otherwise the idempotent skip can pin you to whatever
> `main` pointed at on the first run. Find the sha: `huggingface-cli repo info Comfy-Org/MiniMax-H3`.
>
> A Job spec is immutable, so to re-run after changing the weight set (or a failed run), delete
> it first: `kubectl -n "$NS" delete job comfyui-model-fetch --ignore-not-found`, then re-apply.

## 4. Deploy ComfyUI

```bash
helm template comfyui ./charts/comfyui -n "$NS" \
  -s templates/comfyui.yaml \
  --set comfyui.enabled=true \
  --set comfyui.image="${ECR_URL}:v1" \
  --set comfyui.nodeRole="$POOL" | kubectl apply -f -

# Karpenter launches the g6e node on first scheduling (a few minutes), then the pod pulls the
# image and starts. The startupProbe tolerates a long cold start.
kubectl -n "$NS" get nodeclaims -w             # a comfyui claim appears, then Ready (Ctrl-C)
kubectl -n "$NS" rollout status deploy/comfyui --timeout=20m
```

## 5. Open the Web UI and generate one video

ComfyUI is never exposed publicly — reach it over port-forward:

```bash
NAMESPACE="$NS" ./scripts/port-forward.sh       # leave running; opens http://localhost:8188
```

In the browser (http://localhost:8188), do the **one-time** API-format export (see
`workflows/README.md` for why this manual step exists):

1. Menu → **Open** → `workflows/video_minimax_h3_t2v.ui.json`.
2. Settings → enable **Dev mode options** → menu → **Save (API Format)**.
3. Save as `workflows/video_minimax_h3_t2v.api.json`.

You can now generate from the UI directly (**Queue Prompt**) to confirm it works, and/or run it
headlessly:

```bash
python3 scripts/run_smoke.py workflows/video_minimax_h3_t2v.api.json \
  --out ./out \
  --prompt "a red fox running through snow at dusk, cinematic, shallow depth of field"

# → posts to /prompt, polls /history, and downloads the .mp4 (with audio) into ./out
```

The generated video (24 fps, native stereo audio, up to ~15 s) lands in `./out/` and also
persists on the OpenZFS volume under `minimax-h3/output/`.

## 6. Tear down

The ComfyUI pod carries `karpenter.sh/do-not-disrupt`, which blocks Karpenter from draining it
voluntarily — good while running, but on destroy it can stall the NodeClaim finalizer. Delete
the workloads first so the node drains cleanly (the pool's `terminationGracePeriod` is the
backstop if you forget):

```bash
kubectl -n comfyui delete deploy comfyui --ignore-not-found
kubectl -n comfyui delete job comfyui-model-fetch --ignore-not-found

cd terraform
terraform destroy    # removes the cluster, GPU node, OpenZFS (and its data), and the ECR repo
```

> The destroy drains the GPU node first and can take ~10 min (see the base module's README
> "Known limitations"). The OpenZFS filesystem — including the downloaded weights — is deleted;
> they are re-downloadable, so this is intentional.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `kubectl` → `Unauthorized` | kubectl runs as a different principal than the applying one. Re-run `update-kubeconfig` with the same `--profile`; confirm with `aws sts get-caller-identity`. |
| ComfyUI pod stuck `Pending` | GPU node still launching (`kubectl get nodeclaims`), or `comfyui.memory` exceeds the node's allocatable → lower it or use a larger `gpu_instance_types` entry. |
| Pod OOM / CUDA OOM on first generation | The 48 GB path is tight with the text encoder + VAE decode. Add `--set comfyui.extraArgs="--lowvram"` or use `g6e.4xlarge` (more host RAM for offload). |
| model-fetch slow / HF 429 | Rerun (idempotent; resumes). It sets `HF_HUB_DISABLE_XET=1`; for a private repo set `modelFetch.hfTokenSecretName`. |
| `/prompt` rejects the workflow | You posted the UI-format JSON. Export API format from the Web UI (step 5). |
| Generated video has no audio | Confirm both VAEs were fetched (`vae/minimax_h3_audio_vae_fp32.safetensors`) and the workflow's audio branch is intact. |

## Next steps

- `docs/PROJECT_STATUS.md` — what is built and verified vs pending.
- `docs/PROJECT_RULES.md` — the design invariants (state isolation, no public UI, no hardcoding).
- `workflows/README.md` — I2V / R2V variants and the format conversion detail.
