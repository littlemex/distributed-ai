#!/usr/bin/env bash
# Build the FreeToken serving image with the cluster's in-cluster rootless BuildKit and push it to
# ECR.
#
#   ./serving/image/build.sh [--yes]
#
# Why in-cluster and not a local `docker build`: this platform builds EKS-bound images with the
# in-cluster builder (infra/eks image-builder / image-builder-lib), not on a workstation. It is also
# the practical choice here -- the CUDA 13.0.x devel base is several GB and the image adds torch
# plus a compiled CUDA extension, so building beside ECR inside the VPC avoids pushing multiple GB
# up a home connection.
#
# The build context is shipped as a ConfigMap (Dockerfile only), which is the documented path for an
# image that is not a committed sub-path of a repo the builder can clone.
set -euo pipefail
export AWS_PAGER=""

HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
# shellcheck source=/dev/null
. ./image.env

ASSUME_YES=0
while [ $# -gt 0 ]; do case "$1" in --yes) ASSUME_YES=1; shift;; *) echo "unknown arg: $1" >&2; exit 2;; esac; done

CTX="${FT_KUBE_CONTEXT:-$(kubectl config current-context)}"
# AWS_PROFILE is honoured by the CLI directly from the environment, so there is no --profile
# plumbing here. An array-based one would also break under `set -u` on bash 3.2/4.3, where
# expanding an EMPTY array is an unbound-variable error (macOS still ships bash 3.2).
BUILDER_NS="${FT_BUILDER_NAMESPACE:-image-builder}"
# The builder's own defaults (8Gi memory / 30Gi disk) are sized for small images and are not enough
# here, in both dimensions:
#   memory -- installing torch and compiling freetoken's CUDA extension exceeds 8Gi and the pod is
#             OOMKilled with exit 137 and NO buildkit log (SIGKILL, not a failed build step).
#   disk   -- peak build disk is roughly the pushed image size x4-5 uncompressed, and a CUDA 13
#             devel base plus torch is already several GB before that multiplier.
# These requests also steer Karpenter to a large enough node in the cpu pool.
BUILD_MEMORY="${FT_BUILD_MEMORY:-24Gi}"
BUILD_CPU="${FT_BUILD_CPU:-6}"
BUILD_DISK="${FT_BUILD_DISK:-120Gi}"
INFRA_CHARTS="${FT_INFRA_CHARTS:-$HERE/../../../infra/eks/charts}"

log(){ printf '\n\033[1;32m[build]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[build][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl is required"
command -v helm >/dev/null || die "helm is required"
command -v aws >/dev/null || die "aws is required"

CTX_CLUSTER="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CTX')].context.cluster}" 2>/dev/null || true)"
case "$CTX_CLUSTER" in arn:aws:eks:*) :;; *) die "context '$CTX' is not an EKS ARN";; esac
REGION="$(printf '%s' "$CTX_CLUSTER" | sed -n 's#^arn:aws:eks:\([^:]*\):.*#\1#p')"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REPO_URL="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"

[ -d "$INFRA_CHARTS/experiments" ] || die "cannot find the infra charts at $INFRA_CHARTS (set FT_INFRA_CHARTS)"
kubectl --context "$CTX" get ns "$BUILDER_NS" >/dev/null 2>&1 \
  || die "namespace $BUILDER_NS not found; the in-cluster image builder is not installed on this cluster"

echo "  image  : ${REPO_URL}:${TAG}"
echo "  base   : ${BASE_IMAGE}"
echo "  ref    : ${FREETOKEN_REF}"
echo "  builder: in-cluster ($BUILDER_NS on $CTX)"
[ "$ASSUME_YES" = 1 ] || { read -r -p "Proceed? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || die "aborted by user"; }

aws ecr describe-repositories --region "$REGION" --repository-names "$ECR_REPO" >/dev/null 2>&1 \
  || aws ecr create-repository --region "$REGION" --repository-name "$ECR_REPO" \
       --image-scanning-configuration scanOnPush=true >/dev/null

CM="freetoken-ctx-${TAG//[^a-zA-Z0-9-]/-}"
log "publishing the build context as configmap $CM"
kubectl --context "$CTX" -n "$BUILDER_NS" delete configmap "$CM" --ignore-not-found >/dev/null 2>&1 || true
kubectl --context "$CTX" -n "$BUILDER_NS" create configmap "$CM" \
  --from-file=Dockerfile=./Dockerfile >/dev/null
kubectl --context "$CTX" -n "$BUILDER_NS" patch configmap "$CM" -p '{"immutable":true}' >/dev/null

JOB="build-freetoken"
# A Job's pod template is immutable, so re-applying the same <jobName>-<tag> either errors on an
# immutable field or -- worse -- leaves the PREVIOUS completed Job in place, whereupon the wait
# below succeeds instantly and reports a push that never happened. Delete first.
kubectl --context "$CTX" -n "$BUILDER_NS" delete job "${JOB}-${TAG}" --ignore-not-found --wait=true >/dev/null 2>&1 || true

# The experiments chart depends on image-builder-lib by file:// path, and its charts/ dir and
# Chart.lock are gitignored build artifacts, so a fresh clone has neither. Resolve them here rather
# than making the operator remember: without this, `helm template` fails with
# "found in Chart.yaml, but missing in charts/ directory".
if [ ! -d "$INFRA_CHARTS/experiments/charts" ]; then
  log "resolving the experiments chart's dependencies"
  helm dependency build "$INFRA_CHARTS/experiments" >/dev/null || die "helm dependency build failed for $INFRA_CHARTS/experiments"
fi

log "submitting the build job"
# buildArgs, not Dockerfile defaults: image.env is the single source of truth for the base image,
# the FreeToken ref, and the torch range. Passed with --set-json because helm's --set splits on
# commas and TORCH_SPEC contains one (torch>=2.11,<2.12).
BUILD_ARGS_JSON="$(python3 - "$BASE_IMAGE" "$FREETOKEN_REPO" "$FREETOKEN_REF" "$TORCH_SPEC" <<'PY'
import json, sys
print(json.dumps({"BASE_IMAGE": sys.argv[1], "FREETOKEN_REPO": sys.argv[2],
                  "FREETOKEN_REF": sys.argv[3], "TORCH_SPEC": sys.argv[4]}))
PY
)"
helm template ft "$INFRA_CHARTS/experiments" -s templates/image-build-custom.yaml \
  --set imageBuild.enabled=true \
  --set imageBuild.jobName="$JOB" \
  --set imageBuild.repository="$REPO_URL" \
  --set imageBuild.tag="$TAG" \
  --set imageBuild.contextSource=configMap \
  --set imageBuild.contextConfigMap="$CM" \
  --set-json imageBuild.buildArgs="$BUILD_ARGS_JSON" \
  --set imageBuild.memory="$BUILD_MEMORY" \
  --set imageBuild.cpu="$BUILD_CPU" \
  --set imageBuild.ephemeralStorage="$BUILD_DISK" \
  | kubectl --context "$CTX" apply -f - >/dev/null

log "waiting for the build (a CUDA devel base plus torch plus a compiled extension is not quick)"
kubectl --context "$CTX" -n "$BUILDER_NS" wait --for=condition=complete "job/${JOB}-${TAG}" --timeout=60m \
  || { kubectl --context "$CTX" -n "$BUILDER_NS" logs "job/${JOB}-${TAG}" --tail=80 2>/dev/null || true
       die "build job did not complete"; }

log "pushed ${REPO_URL}:${TAG}"
