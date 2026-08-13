#!/usr/bin/env bash
# GPU test cases. Files under cases/ group functions by area; each test's layer and suite are
# declared in registry.sh (the single source).

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
  local rc=0
  ensure_storage_pvcs || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  apply_manifest gpu-fsx-mount-pod.yaml
  wait_for_pod "$NAMESPACE" gpu-fsx-mount-test Succeeded "$TIMEOUT_GPU"
}
