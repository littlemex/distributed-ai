# Bbox-grounded OCR / document-VLM serving on EKS

Serve several document readers — PaddleOCR, the dots.ocr document VLM, and classic
Tesseract — as in-cluster HTTP services that all speak ONE `/extract` contract: for each
piece of text they return what was read, its pixel bounding box, and (when the engine emits
one) a confidence. Independent, grounded readings of the same page are the raw material for
catching a confident misread — an engine that disagrees on a value, or on where it sits, is
the signal to abstain or escalate.

This project is a thin workload layer on top of the reusable [`../infra/eks`](../infra/eks)
module. It **reuses an existing cluster** — it does not provision one — and reuses that
module's in-cluster image builder to build the serving images. The base module is never
copied or edited.

The `/extract` contract, the coordinate convention, and the engine-set rationale are in
[`docs/DESIGN.md`](docs/DESIGN.md).

## How it fits together

```
                         Existing EKS cluster
                         │
  charts/ocr-serving ────┤  per engine, each toggled on its own:
  (helm template |       │    1. image-build-<engine>  → rootless BuildKit builds the image
   kubectl apply)        │       in-cluster and pushes it to ECR (reuses the base module's
                         │       image-builder ServiceAccount + Pod Identity)
                         │    2. <engine>               → Deployment (1 replica) + ClusterIP
                         │       Service exposing POST /extract on :8000
                         │
                         │  paddleocr (CPU) · dots-ocr (GPU) · tesseract (CPU)
                         │
  kubectl port-forward ──┘  → http://localhost:8000/extract  (no auth → never public)
```

Everything runs in the cluster: no local Docker (a rootless BuildKit Job builds each image),
and model weights are baked into the images, so a pod does no network fetch at startup and
needs no shared storage.

## Key design decisions

| Decision | Why |
|---|---|
| **One `/extract` contract, several engines** | A verifier compares channels token-for-token only if they share a wire format. See `docs/DESIGN.md`. |
| **Mixed engine set (2 CV + 1 VLM), not more VLMs** | Independence buys error-correction only when errors are uncorrelated; VLMs share failure modes, so a classic-CV channel (Tesseract) adds more than a second VLM. |
| **Grounded tokens, not parsed fields** | Field-value localization (keyword → nearest value box) is a research variable; the servers stay at the token primitive so channels are comparable and a new engine only emits tokens. |
| **Weights baked into the image** | No startup download and no PVC → stateless pods, which suits a cluster whose only StorageClass is EBS. |
| **`confidence: null` when an engine emits none** | Never fabricate `1.0`; a consumer must tell "sure" from "no opinion" for selective verification. |
| **ClusterIP only, port-forward access** | The engines have no auth, so they are never exposed publicly. |
| **In-cluster rootless BuildKit via `image-builder-lib`** | No local Docker/finch; the base module's builder mechanism (ECR + Pod Identity) is reused, not reimplemented. |

## Prerequisites

- `kubectl`, `helm` (v3.8+ for OCI/library charts), and the `aws` CLI, authenticated to the
  account that owns the target cluster.
- An existing EKS cluster with the base module's in-cluster image builder deployed (the
  `image-builder` namespace + ServiceAccount with ECR push via Pod Identity).
- An ECR repository the builder can push to and the nodes can pull from. Two options:
  - **Borrow the base module's builder repo** (no extra IAM): the builder ServiceAccount can
    already push to it; each engine uses a distinct tag (`tess-v1` / `paddle-v1` / `dots-v1`).
  - **Dedicated repos**: create per-engine ECR repos and extend the builder role's push
    permission (base module input `image_builder_additional_ecr_repository_arns`), then pass
    the repo URI as `ECR_REPO`.

Set the environment for the commands below (values come from your account, not hardcoded here):

```bash
export CLUSTER=<your-eks-cluster-name>
export ECR_REPO=<your-ecr-repo-uri>          # push + pull target, e.g. from `aws ecr describe-repositories`
export REGION=<your-region>                  # optional; derived from ECR_REPO if omitted
export GPU_POOL=<gpu-node-role>              # node-role label of the GPU pool (default: gpu-ddp)
```

## Quickstart

One command builds the selected engines in-cluster and deploys them (idempotent; re-runnable):

```bash
# all three engines
CLUSTER=$CLUSTER ECR_REPO=$ECR_REPO ./scripts/up.sh

# just the CPU engine (fastest to stand up)
CLUSTER=$CLUSTER ECR_REPO=$ECR_REPO ENGINES="tesseract" ./scripts/up.sh
```

`up.sh` never switches your active kubectl context (it addresses the cluster with an explicit
`--context`). The image is built by BuildKit from a **pushed** git ref (`GIT_REF`, default: the
current branch if pushed, else `main`) — commit and push this directory before the first build.

Then reach an engine and send an image:

```bash
./scripts/port-forward.sh tesseract          # → http://localhost:8000
python3 scripts/run_smoke.py receipt.png --url http://localhost:8000
```

Compare several engines on the same page (forward each to its own local port first):

```bash
python3 scripts/run_smoke.py receipt.png \
  --url tesseract=http://localhost:8001 \
  --url paddleocr=http://localhost:8002 \
  --url dots-ocr=http://localhost:8003 \
  --find 12.000
```

`--find` reports which engines read a given string and at what box — an engine that disagrees
is exactly the cross-channel signal to act on.

### Do it by hand (what `up.sh` runs)

```bash
helm dependency build ./charts/ocr-serving          # vendor image-builder-lib once

# build (rootless BuildKit → ECR)
helm template ocr ./charts/ocr-serving -s templates/image-build-tesseract.yaml \
  --set imageBuild.enabled=true --set imageBuild.repository=$ECR_REPO | kubectl apply -f -
kubectl -n image-builder wait --for=condition=complete job/build-ocr-tesseract-tess-v1 --timeout=20m

# serve
kubectl create ns ocr-serving --dry-run=client -o yaml | kubectl apply -f -
helm template ocr ./charts/ocr-serving -n ocr-serving -s templates/tesseract.yaml \
  --set tesseract.enabled=true --set tesseract.image=$ECR_REPO:tess-v1 | kubectl apply -f -
kubectl -n ocr-serving rollout status deploy/tesseract --timeout=10m
```

paddleocr is the same with `-s templates/paddleocr.yaml` (CPU, no `nodeRole` override needed).
The GPU engine dots-ocr adds `--set dotsOcr.nodeRole=$GPU_POOL`.

## Engines

- **tesseract** (CPU, `node-role: cpu`) — smallest and fastest to stand up. Word-level boxes
  and a real per-word confidence. The independent, non-VLM channel.
- **paddleocr** (CPU) — PP-OCR detection + recognition. Rotated quad per line + a per-line
  score. Runs on CPU (the GPU wheel's CUDA build deps do not resolve cleanly); the PaddleOCR-VL
  0.9B model or a GPU variant can be swapped in behind the same contract later.
- **dots-ocr** (GPU) — the dots.ocr document VLM (~3B, baked into the image). Layout blocks
  with bbox + text; no per-element confidence (reported as `null`). Heaviest image and load.

## Troubleshooting

- **Build Job fails at `ecr-login`** — the `image-builder` ServiceAccount lacks push to
  `ECR_REPO`. Borrow the base module's builder repo, or extend the builder role's push perms.
  Inspect: `kubectl -n image-builder logs job/<build-job> -c ecr-login`.
- **Pod stuck `0/1 Ready`** — the model is still loading (`/readyz` returns 503 until it is).
  `kubectl -n ocr-serving logs deploy/<engine>` shows the load; the dots-ocr ~3B model is the
  slowest. If it stays not-ready, `/readyz` returns the load error in its body.
- **GPU pod `Pending`** — the GPU pool has no capacity or the `nodeRole` does not match the
  pool's `node-role` label. Check `kubectl get nodes -L node-role` and `GPU_POOL`.
- **Rebuild the same tag** — a completed build Job is a no-op on re-apply; bump the tag
  (`PADDLE_TAG=paddle-v2 ...`) or delete the Job first.
