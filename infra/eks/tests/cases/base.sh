#!/usr/bin/env bash
# Cluster smoke test cases. Files under cases/ group functions by area; each test's layer and suite
# are declared in registry.sh (the single source).

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
    | grep -q '^jobset-'
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

# Accelerator device plugins: the NVIDIA GPU device plugin (GPU Operator), the EFA device
# plugin, the Neuron device plugin, and the opt-in gdrcopy device plugin. Each is only
# present/scheduled when the matching pool type exists (or, for gdrcopy, when
# var.gdrcopy_device_plugin_enabled = true), so this asserts "if the DaemonSet exists and
# wants pods, they are all Ready" and treats a missing or zero-desired DaemonSet as
# not-applicable (a cluster with no GPU/EFA/Neuron pool, or with gdrcopy left off, legitimately
# runs none of these). This closes the gap where a broken device plugin — the mechanism that
# advertises nvidia.com/gpu / vpc.amazonaws.com/efa / aws.amazon.com/neuron / gdrcopy/gdrdrv —
# went entirely untested even though EFA dynamic derivation and Neuron support are core features.
test_device_plugins() {
  # ns:name pairs. GPU device plugin lives in gpu-operator; EFA/Neuron plugins in kube-system.
  for entry in \
    "gpu-operator:nvidia-device-plugin-daemonset" \
    "kube-system:aws-efa-k8s-device-plugin" \
    "kube-system:neuron-device-plugin-daemonset" \
    "kube-system:neuron-device-plugin" \
    "kube-system:gdrcopy-device-plugin"; do
    local ns="${entry%%:*}" ds="${entry##*:}" desired ready
    desired=$(kubectl get daemonset "$ds" -n "$ns" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "")
    # Absent DaemonSet (no such pool) or zero desired → not applicable, skip this one.
    [ -z "$desired" ] && continue
    [ "$desired" -eq 0 ] && continue
    ready=$(kubectl get daemonset "$ds" -n "$ns" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
    if [ "$desired" != "$ready" ]; then
      log_info "device plugin $ns/$ds: desired=$desired ready=$ready (not all pods Ready)"
      return 1
    fi
  done
  return 0
}

ensure_storage_pvcs() {
  local deadline fsx_status openzfs_status rc=0
  resolve_storage_vars || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  apply_manifest storage-test-pv-fsx.yaml
  apply_manifest storage-test-pv-openzfs.yaml
  apply_manifest storage-test-pvc.yaml
  deadline=$(($(date +%s) + 30))
  while true; do
    fsx_status=$(kubectl get pvc fsx-claim-test -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    openzfs_status=$(kubectl get pvc openzfs-claim-test -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$fsx_status" = "Bound" ] && [ "$openzfs_status" = "Bound" ] && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 3
  done
}

test_storage_mount() {
  local rc=0
  ensure_storage_pvcs || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  apply_manifest storage-mount-pod.yaml
  wait_for_pod "$NAMESPACE" storage-mount-test Succeeded 120
}
