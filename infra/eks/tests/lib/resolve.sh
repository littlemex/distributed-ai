#!/usr/bin/env bash
# Runtime value derivation. Values come from Terraform or Kubernetes, not literals.

tf_out() {
  (cd "$SCRIPT_DIR/.." && terraform output -raw "$1" 2>/dev/null) || true
}

resolve_cluster_name() {
  if [ -n "${CLUSTER_NAME:-}" ]; then
    return 0
  fi
  CLUSTER_NAME="$(tf_out cluster_name)"
  if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME="$(kubectl config current-context 2>/dev/null | sed -n 's|.*/cluster/||p')"
  fi
  export CLUSTER_NAME
}

resolve_region() {
  if [ -n "${AWS_REGION_OPT:-}" ]; then
    return 0
  fi
  AWS_REGION_OPT="$(tf_out region)"
  # The kubectl context is asked before AWS_DEFAULT_REGION because it names the cluster under test:
  # terraform output can come back empty (no credentials in the environment, since the profile is
  # carried as a flag), and an ambient default region then silently points every aws call in the suite
  # at a region the cluster is not in.
  if [ -z "$AWS_REGION_OPT" ]; then
    AWS_REGION_OPT="$(kubectl config current-context 2>/dev/null | sed -n 's|^arn:aws[a-z-]*:eks:\([a-z0-9-]*\):.*|\1|p')"
  fi
  if [ -z "$AWS_REGION_OPT" ]; then
    AWS_REGION_OPT="${AWS_DEFAULT_REGION:-}"
  fi
  export AWS_REGION_OPT
}

resolve_gpu_nodepool() {
  local pools pool nvidia_pool
  if [ -n "${GPU_NODEPOOL:-}" ]; then
    return 0
  fi
  # Derive an NVIDIA pool only. The GPU smoke pod requests nvidia.com/gpu, so a non-NVIDIA
  # accelerator pool (e.g. Neuron) would leave it unschedulable and fail the wrong way; never guess
  # a non-NVIDIA pool. Prefer the live cluster; fall back to the module's accelerator_pools.
  pools="$(kubectl get nodepool -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  while IFS= read -r pool; do
    [ -n "$pool" ] || continue
    if nodepool_indicates_nvidia "$pool"; then
      nvidia_pool="$pool"
      break
    fi
  done <<< "$pools"
  GPU_NODEPOOL="${nvidia_pool:-}"
  if [ -z "$GPU_NODEPOOL" ]; then
    GPU_NODEPOOL="$(tf_console 'try([for n, p in var.accelerator_pools : n if p.device_plugin == "nvidia"][0], "")' 2>/dev/null || true)"
  fi
  export GPU_NODEPOOL
}

nodepool_indicates_nvidia() {
  local pool="$1" nodeclass combined
  nodeclass="$(kubectl get nodepool "$pool" -o jsonpath='{.spec.template.spec.nodeClassRef.name}' 2>/dev/null || true)"
  combined="$pool
$(kubectl get nodepool "$pool" -o jsonpath='{.spec.template.metadata.labels}{"\n"}{range .spec.template.spec.requirements[*]}{.key}{"="}{.operator}{":"}{.values}{"\n"}{end}' 2>/dev/null || true)
$(kubectl get ec2nodeclass "$nodeclass" -o jsonpath='{.metadata.name}{"\n"}{.spec.tags}{"\n"}{.spec.amiSelectorTerms}' 2>/dev/null || true)"
  printf '%s\n' "$combined" | tr '[:upper:]' '[:lower:]' | grep -Eq 'nvidia|nvidia\.com/gpu|instance-gpu-manufacturer.*nvidia'
}

resolve_clone_source_pv_by_driver() {
  local driver="$1"
  kubectl get pv -l 'app.kubernetes.io/managed-by!=eks-regression-tests' -o jsonpath="{range .items[?(@.spec.csi.driver==\"$driver\")]}{.metadata.name}{\"\\n\"}{end}" 2>/dev/null \
    | sed -n '1p'
}

safe_name() {
  # Two-stage tr: mixing a POSIX class with a literal in one SET1 is not portable (BSD tr).
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr -cs 'a-z0-9-' '-' | sed 's/^-//; s/-$//'
}

# Single source of truth for the cluster-scoped test PV names (the FSx/OpenZFS storage-mount clones).
# Derived from the namespace so runs with different --namespace values never collide, and referenced
# by both the storage test (as clone targets) and the setup/teardown cleanup, so the two never drift.
test_pv_names() {
  local suffix
  suffix="$(safe_name "$NAMESPACE")"
  printf '%s %s\n' "${suffix}-fsx-test-pv" "${suffix}-openzfs-test-pv"
}

assert_test_pv_free() {
  local name="$1" owner
  if ! kubectl get pv "$name" >/dev/null 2>&1; then
    return 0
  fi
  owner="$(kubectl get pv "$name" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
  if [ "$owner" = eks-regression-tests ]; then
    return 0
  fi
  log_fail "PV $name already exists without app.kubernetes.io/managed-by=eks-regression-tests"
  log_fail "  refusing to overwrite a cluster-scoped PV; pass a fresh --namespace"
  return 1
}

resolve_storage_vars() {
  local fsx_pv openzfs_pv
  fsx_pv="$(resolve_clone_source_pv_by_driver fsx.csi.aws.com)"
  openzfs_pv="$(resolve_clone_source_pv_by_driver fsx.openzfs.csi.aws.com)"
  if [ -z "$fsx_pv" ] || [ -z "$openzfs_pv" ]; then
    # A skip, not a failure: a cluster built without shared storage has no source PVs to clone, and
    # log_fail here printed [NG] immediately before the SKIP line, which reads as a broken cluster.
    log_info "source FSx and OpenZFS PVs not found; shared storage is not enabled on this cluster"
    return 2
  fi

  # Test PV names come from the single source (test_pv_names) so cleanup and tests never drift.
  read -r FSX_TEST_PV_NAME OPENZFS_TEST_PV_NAME _ <<< "$(test_pv_names)"
  assert_test_pv_free "$FSX_TEST_PV_NAME" || return 1
  assert_test_pv_free "$OPENZFS_TEST_PV_NAME" || return 1
  FSX_VOLUME_HANDLE="$(kubectl get pv "$fsx_pv" -o jsonpath='{.spec.csi.volumeHandle}')"
  FSX_DNS_NAME="$(kubectl get pv "$fsx_pv" -o jsonpath='{.spec.csi.volumeAttributes.dnsname}')"
  FSX_MOUNT_NAME="$(kubectl get pv "$fsx_pv" -o jsonpath='{.spec.csi.volumeAttributes.mountname}')"
  OPENZFS_VOLUME_HANDLE="$(kubectl get pv "$openzfs_pv" -o jsonpath='{.spec.csi.volumeHandle}')"
  OPENZFS_DNS_NAME="$(kubectl get pv "$openzfs_pv" -o jsonpath='{.spec.csi.volumeAttributes.DNSName}')"
  if [ -z "$FSX_VOLUME_HANDLE" ] || [ -z "$OPENZFS_VOLUME_HANDLE" ]; then
    log_fail "source PV CSI handles not found"
    return 2
  fi
  export FSX_TEST_PV_NAME OPENZFS_TEST_PV_NAME FSX_VOLUME_HANDLE FSX_DNS_NAME FSX_MOUNT_NAME OPENZFS_VOLUME_HANDLE OPENZFS_DNS_NAME
}

