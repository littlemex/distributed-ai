#!/usr/bin/env bash
# Cluster smoke test cases. Files under cases/ group functions by area; each test's layer and suite
# are declared in registry.sh (the single source).

# `producer | grep -q ...` is a race under `set -o pipefail`: grep exits at its first match and closes
# the pipe, and if the producer has not finished writing it dies of SIGPIPE, which pipefail turns into
# exit 141 for the whole pipeline. Measured: this test passed and then reported `exit 141` on the next
# run against an unchanged cluster. Reading the output into a variable first removes the pipe, so the
# result depends on the cluster rather than on who finished first.
test_control_plane() {
  local status health
  status="$(aws_cmd eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.status' --output text)"
  [ "$status" = ACTIVE ] || { printf 'cluster status is %s\n' "$status" >&2; return 1; }
  health="$(kubectl get --raw /healthz 2>/dev/null || true)"
  case "$health" in *ok*) ;; *) printf '/healthz said "%s"\n' "$health" >&2; return 1 ;; esac
}

test_system_nodes() {
  local count states
  count=$(kubectl get nodes -l 'eks.amazonaws.com/nodegroup' --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -ge 2 ] || return 1
  states="$(kubectl get nodes -l 'eks.amazonaws.com/nodegroup' -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)"
  ! printf '%s\n' "$states" | grep -qv True
}

test_karpenter() {
  local running
  running=$(kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$running" -ge 2 ] || return 1
  local pool_states
  pool_states="$(kubectl get nodepool -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)"
  ! printf '%s\n' "$pool_states" | grep -qv True || return 1
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
  local manager running
  manager="$(kubectl get pods -n kubeflow-system -l app.kubernetes.io/instance=kubeflow-trainer \
    --field-selector=status.phase=Running --no-headers 2>/dev/null)"
  [ -n "$manager" ] || { printf 'no Running kubeflow-trainer pod\n' >&2; return 1; }
  # JobSet is a bundled subchart, so its instance label differs from the parent release; match on
  # the pod name (fullnameOverride: jobset) to stay robust across chart-label changes.
  running="$(kubectl get pods -n kubeflow-system --field-selector=status.phase=Running --no-headers 2>/dev/null)"
  case "$running" in
    jobset-* | *"
"jobset-*) ;;
    *) printf 'no Running jobset- pod in kubeflow-system\n' >&2; return 1 ;;
  esac
}

# A cluster with Karpenter in it is never quiet, and a DaemonSet's status says so. The moment a node
# joins, desiredNumberScheduled counts it, before its pod could possibly be Ready; while a node is being
# consolidated, a terminating pod is still counted. Comparing those two numbers in one snapshot therefore
# reports a broken driver whenever a node happens to be arriving or leaving, which is what made this test
# flaky rather than informative.
#
# Three changes fix that without weakening what is asserted. Each pod is judged against the node it is
# on, and pods on nodes that are not Ready are not this test's business — a node whose kubelet has not
# reported in yet cannot be expected to run a Ready CSI pod, and counting it says nothing about the
# driver. A cluster that is genuinely mid-settle gets a short deadline to converge, so a driver that is
# actually broken still fails, just after the deadline, with a message naming the pods and their nodes so
# that churn and breakage are told apart by reading it. And the whole state is read in a handful of list
# calls rather than one call per object: a pass that costs half a minute would leave no room to retry
# inside the timeout this layer is given, which would turn the deadline into a slower way to flake.

# node<tab>Ready-status for every node, and the names of the Ready ones.
_ready_node_names() {
  kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    2>/dev/null | awk -F'\t' '$2 == "True" { print $1 }'
}

# owner<tab>node<tab>ready<tab>pod for every pod in one namespace that a controller created. The owner is
# read from the pod rather than by matching a chart's labels, so a renamed label cannot make this quietly
# match nothing.
_pod_states() {
  kubectl get pods -n "$1" \
    -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].name}{"\t"}{.spec.nodeName}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.metadata.name}{"\n"}{end}' \
    2>/dev/null
}

# name<tab>spec.replicas<tab>status.availableReplicas for every Deployment in one namespace.
_deploy_states() {
  kubectl get deployments -n "$1" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.replicas}{"\t"}{.status.availableReplicas}{"\n"}{end}' \
    2>/dev/null
}

_daemonset_names() {
  kubectl get daemonsets -n "$1" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}

# Every pod of this DaemonSet that sits on a Ready node must be Ready itself. Prints what is wrong and
# returns 1; returns 2 when there is nothing on a Ready node to judge, which the two callers treat
# differently: the CSI drivers must be somewhere, a device plugin legitimately may not be.
_ds_ready_where_it_counts() {
  local ns="$1" ds="$2" nodes="$3" pods="$4" on_ready=0 bad="" owner node ready pod tab
  tab="$(printf '\t')"
  while IFS="$tab" read -r owner node ready pod; do
    [ "$owner" = "$ds" ] || continue
    [ -n "$node" ] || continue
    printf '%s\n' "$nodes" | grep -qxF "$node" || continue
    on_ready=$((on_ready + 1))
    [ "$ready" = True ] || bad="$bad $pod@$node(ready=${ready:-none})"
  done <<EOF
$pods
EOF
  [ "$on_ready" -gt 0 ] || return 2
  [ -z "$bad" ] || { printf '%s/%s: not Ready on Ready nodes:%s\n' "$ns" "$ds" "$bad"; return 1; }
  return 0
}

# A Deployment is judged the same way and for the same reason: consolidation moves a controller pod, and
# availableReplicas dips while the replacement starts.
_deploy_available() {
  local dep="$1" states="$2" name want got tab found=0
  tab="$(printf '\t')"
  while IFS="$tab" read -r name want got; do
    [ "$name" = "$dep" ] || continue
    found=1
    [ "${want:-0}" -gt 0 ] || { printf 'kube-system/%s: scaled to zero\n' "$dep"; return 1; }
    [ "$want" = "${got:-0}" ] || {
      printf 'kube-system/%s: %s of %s replicas available\n' "$dep" "${got:-0}" "$want"
      return 1
    }
  done <<EOF
$states
EOF
  [ "$found" = 1 ] || { printf 'kube-system/%s: no such deployment\n' "$dep"; return 1; }
  return 0
}

# Re-evaluate until everything agrees or the deadline passes. 40 seconds sits under the 60 the registry
# gives this layer, and a pass costs a few seconds, so a settling cluster gets several attempts and the
# harness's own timeout stays the outer bound rather than something this races.
_settle() {
  local deadline=$(( $(date +%s) + 40 )) problems=""
  while :; do
    problems="$("$@")" && return 0
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 5
  done
  printf '%s\n' "$problems" >&2
  return 1
}

_csi_drivers_agree() {
  local nodes pods deploys problems="" out rc ds dep
  nodes="$(_ready_node_names)"
  [ -n "$nodes" ] || { printf 'no node is Ready\n'; return 1; }
  pods="$(_pod_states kube-system)"
  deploys="$(_deploy_states kube-system)"
  for ds in ebs-csi-node efs-csi-node fsx-csi-node fsx-openzfs-csi-node; do
    rc=0
    out="$(_ds_ready_where_it_counts kube-system "$ds" "$nodes" "$pods")" || rc=$?
    case "$rc" in
      0) ;;
      2) problems="$problems""kube-system/$ds: no pod on any Ready node
" ;;
      *) problems="$problems$out
" ;;
    esac
  done
  for dep in ebs-csi-controller efs-csi-controller fsx-csi-controller fsx-openzfs-csi-controller; do
    out="$(_deploy_available "$dep" "$deploys")" || problems="$problems$out
"
  done
  [ -z "$problems" ] || { printf '%s' "$problems"; return 1; }
  return 0
}

test_csi_drivers() {
  _settle _csi_drivers_agree
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
_device_plugins_agree() {
  local nodes problems="" out rc entry ns ds pods_kube pods_gpu ds_kube ds_gpu pods present
  nodes="$(_ready_node_names)"
  [ -n "$nodes" ] || { printf 'no node is Ready\n'; return 1; }
  pods_kube="$(_pod_states kube-system)"
  pods_gpu="$(_pod_states gpu-operator)"
  ds_kube="$(_daemonset_names kube-system)"
  ds_gpu="$(_daemonset_names gpu-operator)"
  # ns:name pairs. GPU device plugin lives in gpu-operator; EFA/Neuron plugins in kube-system.
  for entry in \
    "gpu-operator:nvidia-device-plugin-daemonset" \
    "kube-system:aws-efa-k8s-device-plugin" \
    "kube-system:neuron-device-plugin-daemonset" \
    "kube-system:neuron-device-plugin" \
    "kube-system:gdrcopy-device-plugin"; do
    ns="${entry%%:*}"; ds="${entry##*:}"
    case "$ns" in
      gpu-operator) present="$ds_gpu"; pods="$pods_gpu" ;;
      *)            present="$ds_kube"; pods="$pods_kube" ;;
    esac
    printf '%s\n' "$present" | grep -qxF "$ds" || continue
    rc=0
    out="$(_ds_ready_where_it_counts "$ns" "$ds" "$nodes" "$pods")" || rc=$?
    # rc 2 means it has no pod on a Ready node, which for a device plugin is the ordinary state of a
    # cluster without that kind of pool. Unlike the CSI drivers, that is not a problem.
    case "$rc" in
      0 | 2) ;;
      *) problems="$problems$out
" ;;
    esac
  done
  [ -z "$problems" ] || { printf '%s' "$problems"; return 1; }
  return 0
}

test_device_plugins() {
  _settle _device_plugins_agree
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
