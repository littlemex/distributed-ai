#!/usr/bin/env bash
# Build the SGLang+DFlash2 custom image and push it to ECR. Reference recipe: edit image.env
# (pin BASE_IMAGE digest and SGLANG_COMMIT) first. Per this platform's policy, EKS images are built
# with the in-cluster rootless BuildKit (image-builder); this script shows the equivalent local
# build for reference and pushes the same tag deploy.sh expects.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
. ./image.env
: "${QWEN_REGION:?set QWEN_REGION}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
IMAGE="$ACCOUNT.dkr.ecr.$QWEN_REGION.amazonaws.com/$ECR_REPO:$TAG"
aws ecr describe-repositories --region "$QWEN_REGION" --repository-names "$ECR_REPO" >/dev/null 2>&1 \
  || aws ecr create-repository --region "$QWEN_REGION" --repository-name "$ECR_REPO" \
       --image-tag-mutability IMMUTABLE >/dev/null
aws ecr get-login-password --region "$QWEN_REGION" | docker login --username AWS --password-stdin \
  "$ACCOUNT.dkr.ecr.$QWEN_REGION.amazonaws.com"
docker build --build-arg BASE_IMAGE="$BASE_IMAGE" --build-arg SGLANG_COMMIT="$SGLANG_COMMIT" -t "$IMAGE" .
docker push "$IMAGE"
echo "pushed $IMAGE"
