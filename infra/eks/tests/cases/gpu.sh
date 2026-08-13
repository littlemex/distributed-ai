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

gpu_node_for_pool() {
  local pool="$1" smoke_node smoke_pool
  smoke_node="$(kubectl get pod gpu-smoke-test -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  if [ -n "$smoke_node" ]; then
    smoke_pool="$(kubectl get node "$smoke_node" -o jsonpath='{.metadata.labels.karpenter\.sh/nodepool}' 2>/dev/null || true)"
    if [ "$smoke_pool" = "$pool" ] && kubectl get node "$smoke_node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
      printf '%s\n' "$smoke_node"
      return 0
    fi
  fi
  kubectl get nodes -l "karpenter.sh/nodepool=$pool" -o json 2>/dev/null \
    | jq -r '.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .metadata.name' \
    | sed -n '1p'
}

node_configz() {
  kubectl get --raw "/api/v1/nodes/$1/proxy/configz"
}

test_kubelet_headroom_live() {
  local expected_reserved expected_eviction node config actual_reserved actual_eviction capacity allocatable delta
  resolve_gpu_nodepool
  [ -n "$GPU_NODEPOOL" ] || return 2
  expected_reserved="$(tf_console "try(var.accelerator_pools[\"$GPU_NODEPOOL\"].kubelet_system_reserved_memory, null)")"
  [ "$expected_reserved" != null ] && [ -n "$expected_reserved" ] || return 2
  expected_eviction="$(tf_console "try(var.accelerator_pools[\"$GPU_NODEPOOL\"].kubelet_eviction_hard_memory_available, \"\")")"
  node="$(gpu_node_for_pool "$GPU_NODEPOOL")"
  [ -n "$node" ] || return 2
  config="$(node_configz "$node")"
  actual_reserved="$(printf '%s' "$config" | jq -r '.kubeletconfig.systemReserved.memory // empty')"
  [ "$actual_reserved" = "$expected_reserved" ] || return 1
  if [ -n "$expected_eviction" ]; then
    actual_eviction="$(printf '%s' "$config" | jq -r '.kubeletconfig.evictionHard["memory.available"] // empty')"
    [ "$actual_eviction" = "$expected_eviction" ] || return 1
  fi
  # Capacity minus Allocatable must be at least the reserved headroom: the kubelet enforced the
  # reservation at the cgroup level, not just accepted the config.
  capacity="$(kubectl get node "$node" -o jsonpath='{.status.capacity.memory}')"
  allocatable="$(kubectl get node "$node" -o jsonpath='{.status.allocatable.memory}')"
  delta="$("$SCRIPT_DIR/../scripts/k8s-quantity.py" sub "$capacity" "$allocatable")"
  "$SCRIPT_DIR/../scripts/k8s-quantity.py" ge "$delta" "$expected_reserved"
}

test_kubelet_headroom_default_live() {
  local pool node config expected actual eviction
  pool="$(tf_console 'try([for n, p in var.accelerator_pools : n if p.device_plugin == "nvidia" && p.kubelet_system_reserved_memory == null][0], "")')"
  [ -n "$pool" ] || return 2
  node="$(gpu_node_for_pool "$pool")"
  [ -n "$node" ] || return 2
  expected="$(tf_console 'local.accelerator_system_reserved_memory')"
  config="$(node_configz "$node")"
  actual="$(printf '%s' "$config" | jq -r '.kubeletconfig.systemReserved.memory // empty')"
  eviction="$(printf '%s' "$config" | jq -r '.kubeletconfig.evictionHard["memory.available"] // empty')"
  [ "$actual" = "$expected" ] && [ -z "$eviction" ]
}
