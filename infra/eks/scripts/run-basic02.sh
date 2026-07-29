#!/usr/bin/env bash
# run-basic02.sh — Basic02 (CPU DDP) を一発で動かすスクリプト
# Usage: ./scripts/run-basic02.sh [--skip-build] [--multi-node-only] [--cleanup]
#
# 前提:
#   - kubectl が distai-eks-blog クラスタを指している
#   - AWS CLI が認証済み (aws sts get-caller-identity が通る)
#   - docker または finch が使える
#   - helm が使える
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CHART_DIR="$REPO_ROOT/infra/eks/charts/experiments"
DOCKERFILE_DIR="$REPO_ROOT/infra/eks/manifests/ddp-sample"

NAMESPACE="${NAMESPACE:-distai}"
SKIP_BUILD=false
MULTI_NODE_ONLY=false
CLEANUP_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-build)      SKIP_BUILD=true; shift ;;
    --multi-node-only) MULTI_NODE_ONLY=true; shift ;;
    --cleanup)         CLEANUP_ONLY=true; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

# --- Auto-detect account, region, container runtime ---
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's|.*\.([a-z]+-[a-z]+-[0-9]+)\..*|\1|')
if [ -z "$REGION" ] || [[ "$REGION" == http* ]]; then
  REGION=$(aws configure get region 2>/dev/null || echo "us-west-2")
fi
ECR_URI="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/ddp-sample"
TAG=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
IMAGE="${ECR_URI}:${TAG}"

# When --skip-build, use the latest tag actually in ECR (local HEAD may differ from pushed tag)
if [ "$SKIP_BUILD" = true ]; then
  ECR_TAG=$(aws ecr describe-images --repository-name ddp-sample --region "$REGION" \
    --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text 2>/dev/null || echo "")
  if [ -n "$ECR_TAG" ] && [ "$ECR_TAG" != "None" ]; then
    IMAGE="${ECR_URI}:${ECR_TAG}"
  fi
fi

if command -v docker &>/dev/null; then
  CTR=docker
elif command -v finch &>/dev/null; then
  CTR=finch
else
  echo "[NG] docker も finch も見つかりません"; exit 1
fi

echo "=== Basic02 CPU DDP ==="
echo "  Account: $ACCOUNT"
echo "  Region:  $REGION"
echo "  Image:   $IMAGE"
echo "  Runtime: $CTR"
echo "  Namespace: $NAMESPACE"
echo ""

# --- Cleanup mode ---
if [ "$CLEANUP_ONLY" = true ]; then
  echo "[INFO] cleaning up..."
  kubectl delete pytorchjob ddp-pytorchjob -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete job ddp-torchrun -n "$NAMESPACE" 2>/dev/null || true
  helm template exp "$CHART_DIR" -n "$NAMESPACE" \
    --set pytorchjobTrain.enabled=true --set pytorchjobTrain.image=x \
    --set torchrunTrain.enabled=true --set torchrunTrain.image=x \
    2>/dev/null | kubectl delete -f - 2>/dev/null || true
  echo "[OK] cleanup done"
  exit 0
fi

# --- Step 1: Build & Push ---
if [ "$SKIP_BUILD" = false ]; then
  echo "[INFO] Step 1: ECR repo + build + push"
  aws ecr describe-repositories --repository-names ddp-sample --region "$REGION" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name ddp-sample --region "$REGION" --query 'repository.repositoryUri' --output text
  aws ecr get-login-password --region "$REGION" | $CTR login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
  $CTR build --platform linux/amd64 -t "$IMAGE" "$DOCKERFILE_DIR"
  $CTR push "$IMAGE" || true
  echo "[OK] Image pushed: $IMAGE"
else
  echo "[SKIP] build (--skip-build)"
fi

# --- Step 2: Namespace ---
echo "[INFO] Step 2: Namespace"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- Step 3: Single-node torchrun ---
if [ "$MULTI_NODE_ONLY" = false ]; then
  echo "[INFO] Step 3: Single-node torchrun (2 procs, gloo)"
  helm template exp "$CHART_DIR" -n "$NAMESPACE" \
    --set sharedStorage.existingClaimName=openzfs-claim \
    --set torchrunTrain.enabled=true \
    --set torchrunTrain.image="$IMAGE" \
    --set torchrunTrain.backend=gloo \
    --set torchrunTrain.nodeRole=cpu \
    --set torchrunTrain.nprocPerNode=2 \
    | kubectl apply -f -

  echo "[INFO] waiting for Job completion (up to 15m)..."
  kubectl wait --for=condition=complete job/ddp-torchrun -n "$NAMESPACE" --timeout=15m
  echo "[OK] torchrun completed"
  echo "--- logs (last 10 lines) ---"
  kubectl logs job/ddp-torchrun -n "$NAMESPACE" --tail=10
  echo ""
  kubectl delete job ddp-torchrun -n "$NAMESPACE"
fi

# --- Step 4: Multi-node PyTorchJob (2 workers, etcd rendezvous) ---
echo "[INFO] Step 4: Multi-node PyTorchJob (2 workers, gloo, etcd)"
helm template exp "$CHART_DIR" -n "$NAMESPACE" \
  --set sharedStorage.existingClaimName=openzfs-claim \
  --set pytorchjobTrain.enabled=true \
  --set pytorchjobTrain.image="$IMAGE" \
  --set pytorchjobTrain.backend=gloo \
  --set pytorchjobTrain.nodeRole=cpu \
  --set pytorchjobTrain.workers=2 \
  --set pytorchjobTrain.nprocPerNode=1 \
  | kubectl apply -f -

echo "[INFO] waiting for PyTorchJob (up to 15m)..."
DEADLINE=$(($(date +%s) + 900))
while true; do
  STATUS=$(kubectl get pytorchjob ddp-pytorchjob -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || echo "")
  FAILED=$(kubectl get pytorchjob ddp-pytorchjob -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
  [ "$STATUS" = "True" ] && break
  [ "$FAILED" = "True" ] && { echo "[NG] PyTorchJob failed"; kubectl logs ddp-pytorchjob-worker-0 -n "$NAMESPACE" --tail=20; exit 1; }
  [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "[NG] timeout"; exit 1; }
  sleep 10
done
echo "[OK] PyTorchJob completed"
echo "--- Worker-0 logs ---"
kubectl logs ddp-pytorchjob-worker-0 -n "$NAMESPACE" --tail=10 2>/dev/null || echo "(pod already cleaned up by operator)"
echo "--- Worker-1 logs ---"
kubectl logs ddp-pytorchjob-worker-1 -n "$NAMESPACE" --tail=10 2>/dev/null || echo "(pod already cleaned up by operator)"
echo ""

# --- Cleanup ---
echo "[INFO] Cleanup"
kubectl delete pytorchjob ddp-pytorchjob -n "$NAMESPACE"
echo ""
echo "=============================="
echo " Basic02 ALL PASSED"
echo "=============================="
