#!/usr/bin/env bash
# Static regression tests. Files under cases/ group functions by area; each test's layer and suite
# are declared in registry.sh (the single source).

terraform_static_ready() {
  terraform -chdir="$SCRIPT_DIR/.." providers >/dev/null 2>&1 \
    && printf 'true\n' | terraform -chdir="$SCRIPT_DIR/.." console -no-color >/dev/null 2>&1
}

test_static_terraform_validate() {
  terraform_static_ready || return 2
  terraform -chdir="$SCRIPT_DIR/.." validate -no-color
}

test_static_userdata_baseline() {
  local result
  terraform_static_ready || return 2
  result="$(tf_console_fixture 'alltrue([for n, p in var.accelerator_pools : local.accelerator_user_data_base_by_pool[n] == local.accelerator_user_data if p.kubelet_system_reserved_memory == null && p.kubelet_eviction_hard_memory_available == ""])')"
  [ "$result" = true ]
}

test_static_userdata_headroom() {
  local system_reserved eviction_set eviction_unset
  terraform_static_ready || return 2
  system_reserved="$(tf_console_fixture 'alltrue([for n, p in var.accelerator_pools : strcontains(local.accelerator_user_data_base_by_pool[n], "systemReserved") && strcontains(local.accelerator_user_data_base_by_pool[n], p.kubelet_system_reserved_memory) if p.kubelet_system_reserved_memory != null])')"
  eviction_set="$(tf_console_fixture 'alltrue([for n, p in var.accelerator_pools : strcontains(local.accelerator_user_data_base_by_pool[n], "evictionHard") && strcontains(local.accelerator_user_data_base_by_pool[n], p.kubelet_eviction_hard_memory_available) if p.kubelet_eviction_hard_memory_available != ""])')"
  eviction_unset="$(tf_console_fixture 'alltrue([for n, p in var.accelerator_pools : !strcontains(local.accelerator_user_data_base_by_pool[n], "evictionHard") if p.kubelet_eviction_hard_memory_available == ""])')"
  [ "$system_reserved" = true ] && [ "$eviction_set" = true ] && [ "$eviction_unset" = true ]
}

test_static_reaper_render() {
  local enabled_ok count_ok dry_run_ok config_dry_run_ok config_pools_ok
  terraform_static_ready || return 2
  enabled_ok="$(tf_console_fixture 'local.accelerator_stuck_node_reaper_enabled == (length(local.accelerator_stuck_node_reaper_pools) > 0)')"
  count_ok="$(tf_console_fixture 'length(local.accelerator_stuck_node_reaper_pools) == length([for n, p in var.accelerator_pools : n if p.stuck_node_reaper_enabled])')"
  dry_run_ok="$(tf_console_fixture 'local.accelerator_stuck_node_reaper_dry_run == anytrue([for n, p in var.accelerator_pools : p.stuck_node_reaper_dry_run if p.stuck_node_reaper_enabled])')"
  config_dry_run_ok="$(tf_console_fixture 'local.accelerator_stuck_node_reaper_config.dry_run == local.accelerator_stuck_node_reaper_dry_run')"
  config_pools_ok="$(tf_console_fixture 'sort(keys(local.accelerator_stuck_node_reaper_config.pools)) == sort([for n, p in var.accelerator_pools : n if p.stuck_node_reaper_enabled])')"
  [ "$enabled_ok" = true ] && [ "$count_ok" = true ] && [ "$dry_run_ok" = true ] && [ "$config_dry_run_ok" = true ] && [ "$config_pools_ok" = true ]
}

test_static_reaper_script() {
  # Run the reaper's own unit tests (dry-run gating, finalizer/termination safety paths), not just a
  # syntax check. The reaper and its tests are dependency-free (stdlib only), so this needs no extra
  # tools beyond python3.
  ( cd "$SCRIPT_DIR/../scripts" && python3 -m unittest test_accelerator_stuck_node_reaper )
}

test_static_neuron_cache_render() {
  local chart pvc_render pvc_count serving_render ddp_render fail_out
  chart="$SCRIPT_DIR/../charts/experiments"
  # Default (neuronCache.create=false): the PVC template renders nothing. `helm --show-only` exits
  # non-zero with "could not find template" when a template yields no manifest, which is exactly the
  # assertion here — no PVC is produced by default. A zero exit means the template emitted something
  # with defaults, i.e. a regression.
  if helm template neuron-cache-render "$chart" \
       --show-only templates/neuron-cache-pvc.yaml >/dev/null 2>&1; then
    return 1
  fi
  # create=true: exactly one PVC, named as requested, bound to the dynamic EFS StorageClass, and
  # with NO volumeName — a dedicated access point is provisioned per PVC (the reason EFS is used
  # over a 1:1 static PV).
  pvc_render="$(helm template neuron-cache-render "$chart" \
    --show-only templates/neuron-cache-pvc.yaml \
    --namespace "$NAMESPACE" \
    --set neuronCache.create=true \
    --set neuronCache.pvcName=neuron-cache-render \
    --set neuronCache.storageClassName=efs-shared)"
  pvc_count="$(printf '%s\n' "$pvc_render" | grep -c '^kind: PersistentVolumeClaim$')"
  [ "$pvc_count" -eq 1 ] || return 1
  printf '%s\n' "$pvc_render" | grep -q '^  name: neuron-cache-render$' || return 1
  printf '%s\n' "$pvc_render" | grep -q '^  storageClassName: "efs-shared"$' || return 1
  if printf '%s\n' "$pvc_render" | grep -q 'volumeName:'; then return 1; fi

  # Fail-fast guards: create=true with an empty pvcName or storageClassName must abort the render
  # (a silent default would provision the wrong volume). `if <assignment>` keeps this errexit-safe:
  # a zero exit means helm did NOT fail, i.e. the guard is missing.
  if fail_out="$(helm template neuron-cache-render "$chart" \
      --show-only templates/neuron-cache-pvc.yaml \
      --set neuronCache.create=true \
      --set neuronCache.pvcName= \
      --set neuronCache.storageClassName=efs-shared 2>&1)"; then return 1; fi
  printf '%s\n' "$fail_out" | grep -q 'requires neuronCache.pvcName' || return 1
  if fail_out="$(helm template neuron-cache-render "$chart" \
      --show-only templates/neuron-cache-pvc.yaml \
      --set neuronCache.create=true \
      --set neuronCache.pvcName=neuron-cache-render \
      --set neuronCache.storageClassName= 2>&1)"; then return 1; fi
  printf '%s\n' "$fail_out" | grep -q 'requires neuronCache.storageClassName' || return 1

  # Wiring: with neuronCache.enabled the serving workload mounts the cache at mountPath and points
  # NEURON_COMPILED_ARTIFACTS under it.
  serving_render="$(helm template neuron-cache-render "$chart" \
    --show-only templates/neuron-serving-vllm.yaml \
    --namespace "$NAMESPACE" \
    --set neuronServingVllm.enabled=true \
    --set neuronCache.enabled=true \
    --set neuronCache.pvcName=neuron-cache-render)"
  printf '%s\n' "$serving_render" | grep -qE 'mountPath: "?/mnt/neuron-cache"?' || return 1
  printf '%s\n' "$serving_render" | grep -q 'NEURON_COMPILED_ARTIFACTS' || return 1

  # The same neuronCache is reused by training: the ddp workload mounts it and points
  # NEURON_COMPILE_CACHE_URL (a distinct env from serving) under mountPath.
  ddp_render="$(helm template neuron-cache-render "$chart" \
    --show-only templates/neuron-ddp.yaml \
    --namespace "$NAMESPACE" \
    --set neuronDdp.enabled=true \
    --set neuronDdp.nodeRole=trn2 \
    --set neuronCache.enabled=true \
    --set neuronCache.pvcName=neuron-cache-render)"
  printf '%s\n' "$ddp_render" | grep -qE 'mountPath: "?/mnt/neuron-cache"?' || return 1
  printf '%s\n' "$ddp_render" | grep -q 'NEURON_COMPILE_CACHE_URL' || return 1
}
