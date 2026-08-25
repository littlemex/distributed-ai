#!/usr/bin/env bash
# Build the profiling platform images with the in-cluster rootless BuildKit and publish them to ECR.
#
# This is the development path. In a steady state the images come from CI and the installer consumes
# published digests; building from a working tree is deliberately opt-in (DEV_BUILD=1) because the
# digest that lands in the cluster then depends on whatever the operator has checked out.
#
# Called by infra/install-profiling.sh, or directly:
#   KCTX=profiling-my-cluster AWS_REGION=us-east-2 \
#     ECR_REGISTRY=<account>.dkr.ecr.us-east-2.amazonaws.com \
#     infra/eks/scripts/build-profiling-images.sh
#
# Idempotent: a tag that already exists in ECR is skipped unless FORCE_REBUILD=1. The build Job is
# deleted and recreated on every attempt, and the build context ConfigMap is applied over itself.
set -euo pipefail

: "${KCTX:?set KCTX to the kubectl context of the target cluster}"
: "${AWS_REGION:?set AWS_REGION}"
: "${ECR_REGISTRY:?set ECR_REGISTRY (<account>.dkr.ecr.<region>.amazonaws.com)}"

eks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
say() { printf '\n--> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

k() { kubectl --context "${KCTX}" "$@"; }
digest_of() {
  aws ecr describe-images --repository-name "$1" --image-ids "imageTag=$2" \
    --query 'imageDetails[0].imageDigest' --output text --region "${AWS_REGION}" 2>/dev/null || true
}
is_digest() { case "$1" in sha256:*) return 0 ;; *) return 1 ;; esac; }

# build <repo> <tag> <dockerfile> <job-name> [build-arg=value ...]
build() {
  local repo="$1" tag="$2" dockerfile="$3" job="$4"; shift 4
  local existing
  existing="$(digest_of "${repo}" "${tag}")"
  if [ "${FORCE_REBUILD:-0}" != "1" ] && is_digest "${existing}"; then
    say "${repo}:${tag} already published (${existing}); skipping"
    return 0
  fi
  say "building ${repo}:${tag} from ${dockerfile}"
  k -n image-builder create configmap "${job}-ctx" \
    --from-file="Dockerfile=${eks_dir}/images/${dockerfile}" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n image-builder delete job "${job}-${tag}" --ignore-not-found >/dev/null

  local set_args=(
    --set imageBuild.enabled=true
    --set "imageBuild.jobName=${job}"
    --set "imageBuild.repository=${ECR_REGISTRY}/${repo}"
    --set "imageBuild.tag=${tag}"
    --set imageBuild.contextSource=configMap
    --set "imageBuild.contextConfigMap=${job}-ctx"
  )
  local arg
  for arg in "$@"; do
    set_args+=(--set "imageBuild.buildArgs.${arg%%=*}=${arg#*=}")
  done
  helm template exp "${eks_dir}/charts/experiments" -s templates/image-build-custom.yaml \
    "${set_args[@]}" | k apply -f - >/dev/null
  k -n image-builder wait --for=condition=complete "job/${job}-${tag}" --timeout=30m ||
    die "build ${job}-${tag} did not complete; see: kubectl --context ${KCTX} -n image-builder logs job/${job}-${tag}"
  say "${repo}:${tag} published as $(digest_of "${repo}" "${tag}")"
}

helm dependency build "${eks_dir}/charts/experiments" >/dev/null

build accelprof v1 Dockerfile.accelprof-analysis build-accelprof-base
base_digest="$(digest_of accelprof v1)"
is_digest "${base_digest}" || die "base image digest unavailable after the build"

build accelprof v1-nsys Dockerfile.accelprof-analysis-nsys build-accelprof-nsys \
  "BASE=${ECR_REGISTRY}/accelprof@${base_digest}"
build accelprof-knowledge v1 Dockerfile.accelprof-knowledge build-accelprof-knowledge

say "analysis  $(digest_of accelprof v1-nsys)"
say "knowledge $(digest_of accelprof-knowledge v1)"
