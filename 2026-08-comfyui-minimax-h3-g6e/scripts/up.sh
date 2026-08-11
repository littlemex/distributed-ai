#!/usr/bin/env bash
# up.sh — one-shot: provision the cluster, build the image, fetch the weights, deploy
#         ComfyUI, and open the Web UI over port-forward.
#
# Idempotent: every step is safe to re-run. `terraform apply` reconciles to the desired
# state, the image build is skipped if the tag already exists in ECR, the PVC/weights are
# created only if missing, and the Deployment is applied (not duplicated). Re-running after
# a partial failure resumes rather than restarting.
#
# Never touches your persistent kubectl context: every kubectl call uses --context with the
# cluster this project creates, so `kubectl config current-context` is unchanged throughout.
#
# FSx for Lustre is OFF (a single-node ComfyUI needs no parallel scratch; the OpenZFS NFS
# layer holds weights + outputs). Pass FSX_LUSTRE=true to override.
#
# Usage:
#   ./scripts/up.sh                 # full bring-up, ends by port-forwarding (Ctrl-C to stop)
#   ./scripts/up.sh --no-forward    # do everything except the final port-forward
#   IMAGE_TAG=v3 ./scripts/up.sh    # build/deploy a specific image tag (default: v2)
#
# Env overrides: IMAGE_TAG, GIT_REF (build fetches the Dockerfile from this PUSHED ref),
#                FSX_LUSTRE, PORT, AWS_PROFILE.
set -euo pipefail

# ── Resolve paths (works from anywhere) ───────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$PROJ_DIR/terraform"
CHART="$PROJ_DIR/charts/comfyui"
SHARED_PVC_TEMPLATE="$PROJ_DIR/../infra/eks/manifests/shared-pvc.yaml"

# ── Tunables ──────────────────────────────────────────────────────────────────
IMAGE_TAG="${IMAGE_TAG:-v2}"                 # v2 = torch 2.8.0+cu126 build (v1 crashes: torch too old)
FSX_LUSTRE="${FSX_LUSTRE:-false}"
PORT="${PORT:-8188}"
NS="comfyui"
DO_FORWARD=true
[ "${1:-}" = "--no-forward" ] && DO_FORWARD=false

# The image is built by BuildKit from a GIT ref, not your local files — so GIT_REF must be a
# ref that is PUSHED to the repo. Default to the current branch if it is pushed, else main.
if [ -z "${GIT_REF:-}" ]; then
  CUR_BRANCH="$(git -C "$PROJ_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  if git -C "$PROJ_DIR" ls-remote --exit-code origin "$CUR_BRANCH" >/dev/null 2>&1; then
    GIT_REF="$CUR_BRANCH"
  else
    GIT_REF="main"
  fi
fi

# AWS profile is threaded to terraform + kubeconfig if set (must be the same principal).
PROFILE_ARGS=()
[ -n "${AWS_PROFILE:-}" ] && PROFILE_ARGS=(--profile "$AWS_PROFILE")

log() { printf '\n\033[1;32m[up]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[up] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for bin in terraform kubectl helm aws; do command -v "$bin" >/dev/null || die "$bin not on PATH"; done
[ -f "$SHARED_PVC_TEMPLATE" ] || die "shared-pvc template not found at $SHARED_PVC_TEMPLATE (run from a full checkout, next to infra/eks)"

# ── 1. Provision the cluster (control plane, GPU pool, OpenZFS, ECR) ───────────
log "1/6 terraform apply (FSx Lustre=$FSX_LUSTRE) — ~15 min on first run, fast if already up"
cd "$TF_DIR"
[ -f terraform.tfvars ] || die "terraform.tfvars missing — cp terraform.tfvars.example terraform.tfvars and set region/account first"
terraform init -input=false >/dev/null
terraform apply -input=false -auto-approve -var "fsx_lustre_enabled=$FSX_LUSTRE"

# Read outputs (authoritative — never hardcode names).
CLUSTER="$(terraform output -raw cluster_name)"
REGION="$(terraform output -raw region)"
ECR_URL="$(terraform output -raw comfyui_ecr_url)"
POOL="$(terraform output -raw comfyui_pool_name)"
OZFS_PV="$(terraform output -raw openzfs_persistent_volume)"
# EKS access-entry ARN form for --context, so we never mutate the user's kubeconfig context.
ACCOUNT="$(aws sts get-caller-identity "${PROFILE_ARGS[@]}" --query Account --output text)"
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"

# Ensure the context exists in kubeconfig WITHOUT switching the active one:
# update-kubeconfig only adds/updates the entry; we always pass --context explicitly below.
log "Ensuring kubeconfig entry for $CLUSTER (active context is left unchanged)"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" "${PROFILE_ARGS[@]}" --alias "$CTX" >/dev/null
K() { kubectl --context "$CTX" "$@"; }

echo "  cluster=$CLUSTER region=$REGION pool=$POOL"
echo "  ecr=$ECR_URL  image_tag=$IMAGE_TAG  git_ref=$GIT_REF"

# ── 2. Build the ComfyUI image in-cluster (skip if the tag is already in ECR) ──
if aws ecr describe-images "${PROFILE_ARGS[@]}" --region "$REGION" \
     --repository-name "$(basename "$ECR_URL")" --image-ids imageTag="$IMAGE_TAG" >/dev/null 2>&1; then
  log "2/6 image $ECR_URL:$IMAGE_TAG already in ECR — skipping build"
else
  log "2/6 building ComfyUI image in-cluster (BuildKit → ECR), ref=$GIT_REF — ~8-10 min"
  K -n image-builder delete job "build-comfyui-$IMAGE_TAG" --ignore-not-found >/dev/null 2>&1 || true
  helm template comfyui "$CHART" -s templates/image-build-comfyui.yaml \
    --set imageBuild.enabled=true \
    --set imageBuild.repository="$ECR_URL" \
    --set imageBuild.tag="$IMAGE_TAG" \
    --set imageBuild.gitRef="$GIT_REF" | K apply -f -
  K -n image-builder wait --for=condition=complete "job/build-comfyui-$IMAGE_TAG" --timeout=45m \
    || die "image build failed — inspect: kubectl --context $CTX -n image-builder logs job/build-comfyui-$IMAGE_TAG"
fi

# ── 3. Namespace + shared PVC (bound to the OpenZFS static PV) ─────────────────
log "3/6 namespace + shared PVC ($OZFS_PV)"
K create namespace "$NS" --dry-run=client -o yaml | K apply -f -
sed "s/__VOLUME_NAME__/${OZFS_PV}/" "$SHARED_PVC_TEMPLATE" | K -n "$NS" apply -f -
K -n "$NS" wait --for=jsonpath='{.status.phase}'=Bound pvc/shared-claim --timeout=3m \
  || die "shared-claim PVC did not bind — check the OpenZFS PV: kubectl --context $CTX get pv $OZFS_PV"

# ── 4. Fetch the MiniMax-H3 weights (~40GB) — idempotent, skips present files ──
log "4/6 fetching MiniMax-H3 weights to the shared volume — ~8-9 min (skips if already present)"
K -n "$NS" delete job comfyui-model-fetch --ignore-not-found >/dev/null 2>&1 || true
helm template comfyui "$CHART" -n "$NS" -s templates/model-fetch.yaml \
  --set modelFetch.enabled=true \
  --set comfyui.image="${ECR_URL}:${IMAGE_TAG}" | K apply -f -
K -n "$NS" wait --for=condition=complete job/comfyui-model-fetch --timeout=75m \
  || die "weight fetch failed — inspect: kubectl --context $CTX -n $NS logs job/comfyui-model-fetch"

# ── 5. Deploy ComfyUI (Karpenter launches the g6e GPU node on first schedule) ──
log "5/6 deploying ComfyUI (Karpenter provisions the g6e node, ~few min)"
helm template comfyui "$CHART" -n "$NS" -s templates/comfyui.yaml \
  --set comfyui.enabled=true \
  --set comfyui.image="${ECR_URL}:${IMAGE_TAG}" \
  --set comfyui.nodeRole="$POOL" | K apply -f -
K -n "$NS" rollout status deploy/comfyui --timeout=20m \
  || die "ComfyUI rollout failed — inspect: kubectl --context $CTX -n $NS logs deploy/comfyui"

# ── 6. Port-forward the Web UI ─────────────────────────────────────────────────
if [ "$DO_FORWARD" = true ]; then
  log "6/6 ComfyUI is up. Forwarding http://localhost:${PORT} (Ctrl-C to stop)"
  echo "  Generate headlessly with:"
  echo "    python3 $PROJ_DIR/scripts/run_smoke.py $PROJ_DIR/workflows/video_minimax_h3_t2v.api.json \\"
  echo "      --out $PROJ_DIR/out --prompt \"...\" --prompt-node 104"
  exec kubectl --context "$CTX" -n "$NS" port-forward svc/comfyui "${PORT}:8188"
else
  log "6/6 ComfyUI is up. Skipping port-forward (--no-forward). To open the UI later:"
  echo "  kubectl --context $CTX -n $NS port-forward svc/comfyui ${PORT}:8188"
fi
