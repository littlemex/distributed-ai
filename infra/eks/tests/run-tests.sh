#!/usr/bin/env bash
# run-tests.sh — EKS infra-layer smoke tests
# Usage: ./run-tests.sh [--with-gpu] [--keep-ns] [--namespace NAME]
#        [--cluster-name NAME] [--region REGION] [--profile PROFILE]
#        [--gpu-count N]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

NAMESPACE="${NAMESPACE:-distai-test}"
CLUSTER_NAME="${CLUSTER_NAME:-distai-eks-blog}"
AWS_REGION_OPT="${AWS_REGION:-us-west-2}"
AWS_PROFILE_OPT="${AWS_PROFILE:-}"
WITH_GPU=false
KEEP_NS=false
TIMEOUT_BASE=60
TIMEOUT_GPU=600
GPU_COUNT=1
# GPU test NodePool. Defaults to gpu-dev for backward compatibility; override with
# --gpu-nodepool to match the accelerator_pools key actually defined in tfvars (e.g. gpu-ddp).
GPU_NODEPOOL=gpu-dev

# Manifest envsubst target variables (explicit list to avoid clobbering $TOKEN etc in Pod scripts)
ENVSUBST_VARS='${NAMESPACE} ${FSX_VOLUME_HANDLE} ${FSX_DNS_NAME} ${FSX_MOUNT_NAME} ${OPENZFS_VOLUME_HANDLE} ${OPENZFS_DNS_NAME} ${GPU_COUNT} ${GPU_NODEPOOL}'

while [[ $# -gt 0 ]]; do
  case $1 in
    --with-gpu)     WITH_GPU=true; shift ;;
    --keep-ns)      KEEP_NS=true; shift ;;
    --namespace)    NAMESPACE="$2"; shift 2 ;;
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --region)       AWS_REGION_OPT="$2"; shift 2 ;;
    --profile)      AWS_PROFILE_OPT="$2"; shift 2 ;;
    --gpu-count)    GPU_COUNT="$2"; shift 2 ;;
    --gpu-nodepool) GPU_NODEPOOL="$2"; shift 2 ;;
    --timeout-base) TIMEOUT_BASE="$2"; shift 2 ;;
    --timeout-gpu)  TIMEOUT_GPU="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

export NAMESPACE GPU_COUNT GPU_NODEPOOL

aws_cmd() {
  local args=("$@")
  [ -n "$AWS_PROFILE_OPT" ] && args+=(--profile "$AWS_PROFILE_OPT")
  args+=(--region "$AWS_REGION_OPT")
  aws "${args[@]}"
}

require_tools() {
  for cmd in kubectl aws envsubst timeout; do
    command -v "$cmd" >/dev/null || { log_fail "required tool not found: $cmd"; exit 1; }
  done
}

ensure_context() {
  local ctx cluster
  ctx=$(kubectl config current-context 2>/dev/null || true)
  cluster=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || true)
  if [[ "$cluster" != *"$CLUSTER_NAME"* ]]; then
    log_fail "current kubectl context ($ctx) does not target $CLUSTER_NAME (got: $cluster)"
    exit 1
  fi
  log_info "kubectl context: $ctx (cluster: $CLUSTER_NAME)"
}

setup_namespace() {
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    log_info "namespace $NAMESPACE already exists — cleaning up"
    kubectl delete namespace "$NAMESPACE" --wait=true --timeout=90s 2>/dev/null || true
    kubectl delete pv fsx-training-test openzfs-shared-test --wait=false 2>/dev/null || true
    local deadline=$(($(date +%s) + 60))
    while kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; do
      [ "$(date +%s)" -ge "$deadline" ] && break
      sleep 3
    done
  fi
  envsubst '$NAMESPACE' < "$SCRIPT_DIR/manifests/namespace.yaml" | kubectl apply -f -
}

teardown_namespace() {
  if [ "$KEEP_NS" = true ]; then
    log_info "keeping namespace $NAMESPACE for inspection (--keep-ns)"
    return
  fi
  log_info "cleaning up namespace $NAMESPACE"
  kubectl delete namespace "$NAMESPACE" --wait=false 2>/dev/null || true
  kubectl delete pv fsx-training-test openzfs-shared-test --wait=false 2>/dev/null || true
}

resolve_storage_vars() {
  FSX_VOLUME_HANDLE=$(kubectl get pv fsx-training -o jsonpath='{.spec.csi.volumeHandle}')
  FSX_DNS_NAME=$(kubectl get pv fsx-training -o jsonpath='{.spec.csi.volumeAttributes.dnsname}')
  FSX_MOUNT_NAME=$(kubectl get pv fsx-training -o jsonpath='{.spec.csi.volumeAttributes.mountname}')
  OPENZFS_VOLUME_HANDLE=$(kubectl get pv openzfs-shared -o jsonpath='{.spec.csi.volumeHandle}')
  OPENZFS_DNS_NAME=$(kubectl get pv openzfs-shared -o jsonpath='{.spec.csi.volumeAttributes.DNSName}')
  [ -n "$FSX_VOLUME_HANDLE" ] && [ -n "$OPENZFS_VOLUME_HANDLE" ] || { log_fail "production PVs (fsx-training / openzfs-shared) not found"; return 1; }
  export FSX_VOLUME_HANDLE FSX_DNS_NAME FSX_MOUNT_NAME OPENZFS_VOLUME_HANDLE OPENZFS_DNS_NAME
}

apply_manifest() {
  envsubst "$ENVSUBST_VARS" < "$SCRIPT_DIR/manifests/$1" | kubectl apply -f -
}

# --- Base tests ---

test_control_plane() {
  aws_cmd eks describe-cluster --name "$CLUSTER_NAME" \
    --query 'cluster.status' --output text | grep -qx ACTIVE
  kubectl get --raw /healthz | grep -q ok
}

test_system_nodes() {
  local count
  count=$(kubectl get nodes -l 'eks.amazonaws.com/nodegroup' --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -ge 2 ] || return 1
  ! kubectl get nodes -l 'eks.amazonaws.com/nodegroup' -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -qv True
}

test_karpenter() {
  local running
  running=$(kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$running" -ge 2 ] || return 1
  ! kubectl get nodepool -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -qv True || return 1
  local nc_count nc_ready
  nc_count=$(kubectl get ec2nodeclass --no-headers 2>/dev/null | wc -l | tr -d ' ')
  nc_ready=$(kubectl get ec2nodeclass -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c True || true)
  [ "$nc_count" -gt 0 ] && [ "$nc_ready" -eq "$nc_count" ] || return 1
}

test_trainer() {
  # Kubeflow Trainer v2 control plane (replaces the old Training Operator v1). Installed by
  # trainer.tf as the "kubeflow-trainer" Helm release into kubeflow-system, with JobSet as a
  # bundled subchart. Assert BOTH the Trainer manager and the JobSet controller have a Running
  # pod — the manager alone would accept a TrainJob but the JobSet controller is what actually
  # creates the worker pods, so a missing JobSet controller is a silent "TrainJob never schedules".
  kubectl get pods -n kubeflow-system -l app.kubernetes.io/instance=kubeflow-trainer \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -q . || return 1
  # JobSet is a bundled subchart, so its instance label differs from the parent release; match on
  # the pod name (fullnameOverride: jobset) to stay robust across chart-label changes.
  kubectl get pods -n kubeflow-system --field-selector=status.phase=Running --no-headers 2>/dev/null \
    | grep -q jobset
}

test_csi_drivers() {
  for ds in ebs-csi-node efs-csi-node fsx-csi-node fsx-openzfs-csi-node; do
    local desired ready
    desired=$(kubectl get daemonset "$ds" -n kube-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
    ready=$(kubectl get daemonset "$ds" -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null)
    [ "$desired" -gt 0 ] && [ "$desired" = "$ready" ] || return 1
  done
  for dep in ebs-csi-controller efs-csi-controller fsx-csi-controller fsx-openzfs-csi-controller; do
    local replicas avail
    replicas=$(kubectl get deployment "$dep" -n kube-system -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
    avail=$(kubectl get deployment "$dep" -n kube-system -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
    [ "$replicas" -gt 0 ] && [ "$replicas" = "$avail" ] || return 1
  done
}

test_storage_mount() {
  resolve_storage_vars || return 1
  apply_manifest storage-test-pv-fsx.yaml
  apply_manifest storage-test-pv-openzfs.yaml
  apply_manifest storage-test-pvc.yaml
  local deadline=$(($(date +%s) + 30))
  while true; do
    local fsx_status openzfs_status
    fsx_status=$(kubectl get pvc fsx-claim-test -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    openzfs_status=$(kubectl get pvc openzfs-claim-test -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$fsx_status" = "Bound" ] && [ "$openzfs_status" = "Bound" ] && break
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 3
  done
  apply_manifest storage-mount-pod.yaml
  wait_for_pod "$NAMESPACE" storage-mount-test Succeeded 120
}

# --- GPU tests ---

test_gpu_node_launch() {
  apply_manifest gpu-smoke-pod.yaml
  wait_for_pod "$NAMESPACE" gpu-smoke-test Succeeded "$TIMEOUT_GPU"
}

test_nvidia_smi() {
  local gpu_lines
  gpu_lines=$(kubectl logs gpu-smoke-test -n "$NAMESPACE" 2>/dev/null | grep -cE "^\| +[0-9]+ " || true)
  [ "$gpu_lines" -ge "$GPU_COUNT" ] || return 1
}

test_cuda_vector_add() {
  apply_manifest gpu-vectoradd-job.yaml
  wait_for_job "$NAMESPACE" cuda-vectoradd "$TIMEOUT_GPU"
  kubectl logs job/cuda-vectoradd -n "$NAMESPACE" 2>/dev/null | grep -q "Test PASSED"
}

test_gpu_fsx_mount() {
  apply_manifest gpu-fsx-mount-pod.yaml
  wait_for_pod "$NAMESPACE" gpu-fsx-mount-test Succeeded "$TIMEOUT_GPU"
}

# --- Main ---

main() {
  require_tools
  ensure_context
  trap teardown_namespace EXIT

  log_info "=== EKS Infra Smoke Tests ==="
  log_info "cluster: $CLUSTER_NAME, namespace: $NAMESPACE, with-gpu: $WITH_GPU, gpu-count: $GPU_COUNT"

  setup_namespace

  log_info "--- Base Tests ---"
  run_test "control-plane" "$TIMEOUT_BASE" test_control_plane || true
  run_test "system-nodes" "$TIMEOUT_BASE" test_system_nodes || true
  run_test "karpenter" "$TIMEOUT_BASE" test_karpenter || true
  run_test "trainer" "$TIMEOUT_BASE" test_trainer || true
  run_test "csi-drivers" "$TIMEOUT_BASE" test_csi_drivers || true
  run_test "storage-mount" 120 test_storage_mount || true

  if [ "$WITH_GPU" = true ]; then
    log_info "--- GPU Tests ---"
    if run_test "gpu-node-launch+nvidia-smi" "$TIMEOUT_GPU" test_gpu_node_launch; then
      run_test "nvidia-smi-check" "$TIMEOUT_BASE" test_nvidia_smi || true
      run_test "cuda-vector-add" "$TIMEOUT_GPU" test_cuda_vector_add || true
      run_test "gpu-fsx-mount" "$TIMEOUT_GPU" test_gpu_fsx_mount || true
    else
      skip_test "nvidia-smi-check" "gpu node did not launch"
      skip_test "cuda-vector-add" "gpu node did not launch"
      skip_test "gpu-fsx-mount" "gpu node did not launch"
    fi
  fi

  print_summary

  [ "$FAIL_COUNT" -eq 0 ]
}

main
