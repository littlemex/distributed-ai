#!/usr/bin/env bash
# GPU test cases. Files under cases/ group functions by area; each test's layer and suite are
# declared in registry.sh (the single source).

test_gpu_node_launch() {
  apply_manifest gpu-smoke-pod.yaml
  wait_for_pod "$NAMESPACE" gpu-smoke-test Succeeded "$TIMEOUT_GPU"
}

# Basic07 end to end: run the SAME workshop scenario (charts/experiments gpuServingVllm) that the
# book documents — deploy -> verify (/v1/models + a chat completion) -> teardown. This is the live
# counterpart to the static gpu-serving contract check.
test_gpu_serving_vllm() {
  local sc="$SCRIPT_DIR/scenarios/basic07-gpu-vllm"
  resolve_gpu_nodepool
  [ -n "$GPU_NODEPOOL" ] || return 2   # SKIP: no NVIDIA pool derived
  # shellcheck disable=SC2064
  trap "NAMESPACE='$NAMESPACE' NODE_ROLE='$GPU_NODEPOOL' bash '$sc/teardown.sh' >/dev/null 2>&1 || true" EXIT
  # shellcheck disable=SC2064
  trap "NAMESPACE='$NAMESPACE' NODE_ROLE='$GPU_NODEPOOL' bash '$sc/teardown.sh' >/dev/null 2>&1 || true; exit 143" TERM
  NAMESPACE="$NAMESPACE" NODE_ROLE="$GPU_NODEPOOL" bash "$sc/deploy.sh" || return 1
  NAMESPACE="$NAMESPACE" bash "$sc/verify.sh" || return 1
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
  local rc=0
  ensure_storage_pvcs || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  apply_manifest gpu-fsx-mount-pod.yaml
  wait_for_pod "$NAMESPACE" gpu-fsx-mount-test Succeeded "$TIMEOUT_GPU"
}
