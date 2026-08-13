#!/usr/bin/env bash
# up.sh — build the selected OCR/doc-VLM engine images in-cluster and deploy them, on an
#         EXISTING cluster (this project reuses a cluster; it does not provision one).
#
# For each engine in $ENGINES it: builds the image with rootless BuildKit (skipped if the
# tag is already in ECR), then deploys the Deployment + ClusterIP Service. Idempotent: every
# step is safe to re-run (a present image tag is skipped, the Deployment is applied not
# duplicated). Re-running after a partial failure resumes.
#
# Never touches your persistent kubectl context: every kubectl call uses --context with the
# target cluster, so `kubectl config current-context` is unchanged throughout.
#
# Required env:
#   CLUSTER    EKS cluster name to deploy onto.
#   ECR_REPO   ECR repository URI images are pushed to AND pulled from (one repo, distinct
#              per-engine tags). Reuse the base module's builder repo, or a dedicated repo.
#
# Optional env:
#   REGION         AWS region (default: derived from the ECR_REPO host).
#   ENGINES        space-separated subset of "tesseract paddleocr dots-ocr" (default: all).
#   NAMESPACE      target namespace (default: ocr-serving).
#   GPU_POOL       node-role of the GPU pool for paddleocr/dots-ocr (default: gpu-ddp).
#   GIT_REF        pushed ref BuildKit clones the Dockerfiles from (default: current branch if
#                  pushed, else main). The image is built from GIT, not your local files.
#   TESS_TAG / PADDLE_TAG / DOTS_TAG   image tags (default: tess-v1 / paddle-v1 / dots-v1).
#   AWS_PROFILE    AWS profile (threaded to aws + kubeconfig).
#   FORWARD        engine to port-forward at the end (default: none).
#
# Usage:
#   CLUSTER=my-cluster ECR_REPO=<uri> ENGINES="tesseract" ./scripts/up.sh
#   CLUSTER=my-cluster ECR_REPO=<uri> ./scripts/up.sh              # all three
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHART="$PROJ_DIR/charts/ocr-serving"

: "${CLUSTER:?set CLUSTER to the EKS cluster name}"
: "${ECR_REPO:?set ECR_REPO to the ECR repository URI (push+pull target)}"
ENGINES="${ENGINES:-tesseract paddleocr dots-ocr}"
NAMESPACE="${NAMESPACE:-ocr-serving}"
GPU_POOL="${GPU_POOL:-gpu-ddp}"
TESS_TAG="${TESS_TAG:-tess-v1}"
PADDLE_TAG="${PADDLE_TAG:-paddle-v1}"
DOTS_TAG="${DOTS_TAG:-dots-v1}"
FORWARD="${FORWARD:-}"

# Region: explicit, else parse <acct>.dkr.ecr.<region>.amazonaws.com out of ECR_REPO.
if [ -z "${REGION:-}" ]; then
  REGION="$(printf '%s' "$ECR_REPO" | sed -n 's/^[0-9]*\.dkr\.ecr\.\([a-z0-9-]*\)\.amazonaws\.com.*/\1/p')"
  [ -n "$REGION" ] || { echo "could not derive REGION from ECR_REPO; set REGION explicitly" >&2; exit 1; }
fi
ECR_REPO_NAME="$(printf '%s' "$ECR_REPO" | sed 's#^[^/]*/##')"

PROFILE_ARGS=(); [ -n "${AWS_PROFILE:-}" ] && PROFILE_ARGS=(--profile "$AWS_PROFILE")
log() { printf '\n\033[1;32m[up]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[up] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
for bin in kubectl helm aws; do command -v "$bin" >/dev/null || die "$bin not on PATH"; done

# GIT_REF: the image is built by BuildKit from a PUSHED ref, not local files.
if [ -z "${GIT_REF:-}" ]; then
  CUR="$(git -C "$PROJ_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  if git -C "$PROJ_DIR" ls-remote --exit-code origin "$CUR" >/dev/null 2>&1; then GIT_REF="$CUR"; else GIT_REF="main"; fi
fi

# ── kubeconfig for the target cluster, WITHOUT switching the active context ─────
ACCOUNT="$(aws sts get-caller-identity "${PROFILE_ARGS[@]}" --query Account --output text)"
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
log "kubeconfig for $CLUSTER (active context left unchanged; using --context $CTX)"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" "${PROFILE_ARGS[@]}" --alias "$CTX" >/dev/null
K() { kubectl --context "$CTX" "$@"; }

log "vendoring the image-builder-lib dependency"
helm dependency build "$CHART" >/dev/null

K create namespace "$NAMESPACE" --dry-run=client -o yaml | K apply -f -

# Per-engine metadata: valuesKey, tag, image-build template, serve template, gpu flag.
engine_meta() {
  case "$1" in
    tesseract) echo "tesseract $TESS_TAG image-build-tesseract.yaml tesseract.yaml false" ;;
    paddleocr) echo "paddleocr $PADDLE_TAG image-build-paddleocr.yaml paddleocr.yaml true" ;;
    dots-ocr)  echo "dotsOcr $DOTS_TAG image-build-dots-ocr.yaml dots-ocr.yaml true" ;;
    *) die "unknown engine '$1' (valid: tesseract paddleocr dots-ocr)" ;;
  esac
}

for engine in $ENGINES; do
  read -r VKEY TAG BUILD_TPL SERVE_TPL GPU <<<"$(engine_meta "$engine")"
  IMG="${ECR_REPO}:${TAG}"
  JOB="build-ocr-${engine}-${TAG}"

  # ── build (skip if the tag is already in ECR) ──
  if aws ecr describe-images "${PROFILE_ARGS[@]}" --region "$REGION" \
       --repository-name "$ECR_REPO_NAME" --image-ids imageTag="$TAG" >/dev/null 2>&1; then
    log "[$engine] image $IMG already in ECR — skipping build"
  else
    log "[$engine] building $IMG in-cluster (BuildKit -> ECR), ref=$GIT_REF"
    K -n image-builder delete job "$JOB" --ignore-not-found >/dev/null 2>&1 || true
    helm template ocr "$CHART" -s "templates/${BUILD_TPL}" \
      --set imageBuild.enabled=true \
      --set imageBuild.repository="$ECR_REPO" \
      --set imageBuild.gitRef="$GIT_REF" | K apply -f -
    K -n image-builder wait --for=condition=complete "job/$JOB" --timeout=60m \
      || die "[$engine] build failed — inspect: kubectl --context $CTX -n image-builder logs job/$JOB"
  fi

  # ── deploy ──
  log "[$engine] deploying to ns/$NAMESPACE"
  SET_ARGS=(--set "${VKEY}.enabled=true" --set "${VKEY}.image=$IMG")
  [ "$GPU" = "true" ] && SET_ARGS+=(--set "${VKEY}.nodeRole=$GPU_POOL")
  helm template ocr "$CHART" -n "$NAMESPACE" -s "templates/${SERVE_TPL}" "${SET_ARGS[@]}" | K apply -f -
  K -n "$NAMESPACE" rollout status "deploy/$engine" --timeout=20m \
    || die "[$engine] rollout failed — inspect: kubectl --context $CTX -n $NAMESPACE logs deploy/$engine"
done

log "done. Services (ClusterIP) in ns/$NAMESPACE:"
K -n "$NAMESPACE" get deploy,svc -l app.kubernetes.io/part-of=ocr-serving

if [ -n "$FORWARD" ]; then
  log "port-forwarding svc/$FORWARD 8000 -> localhost:8000 (Ctrl-C to stop). POST /extract."
  exec kubectl --context "$CTX" -n "$NAMESPACE" port-forward "svc/$FORWARD" 8000:8000
else
  echo "  Reach an engine:  kubectl --context $CTX -n $NAMESPACE port-forward svc/<engine> 8000:8000"
  echo "  Then:             python3 $PROJ_DIR/scripts/run_smoke.py <image> --url http://localhost:8000"
fi
