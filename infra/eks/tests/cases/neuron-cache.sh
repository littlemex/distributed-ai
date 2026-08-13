#!/usr/bin/env bash
# Neuron compile-cache (EFS dynamic access point) test cases. Files under cases/ group functions by
# area; each test's layer and suite are declared in registry.sh (the single source).

# Apply an owned test PVC on the dynamic EFS StorageClass. Intentionally chart-independent: the
# chart's cache PVC render is asserted by the static test (static-neuron-cache-render); these live
# tests exercise the EFS CSI provisioner (dynamic access points), so a minimal PVC is sufficient.
_apply_efs_test_pvc() {
  local ns="$1" name="$2" sc="$3"
  # create (not apply): a name collision must error rather than silently adopt a pre-existing PVC
  # that another process owns.
  kubectl create -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: eks-regression-tests
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ${sc}
  resources:
    requests:
      storage: 1Gi
EOF
}

# Delete a test PVC and, only if the released PV's claimRef points back at it, the PV too; then
# best-effort delete the EFS access point (Retain leaves it otherwise). The EFS directory under the
# access point is not deleted (it remains on the filesystem). Guarded so it never touches a PV it
# does not own.
_cleanup_efs_test_pvc() {
  local ns="$1" name="$2" pv ref handle ap
  pv="$(kubectl -n "$ns" get "pvc/$name" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  kubectl -n "$ns" delete "pvc/$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  [ -n "$pv" ] || return 0
  ref="$(kubectl get "pv/$pv" -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}' 2>/dev/null || true)"
  [ "$ref" = "$ns/$name" ] || return 0
  handle="$(kubectl get "pv/$pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null || true)"
  kubectl delete "pv/$pv" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  # The EFS volumeHandle is the last colon-delimited field: "fs-xxx::fsap-yyy" or, when a
  # subPathPattern is set, "fs-xxx:/sub:fsap-yyy". Take that field and delete it only if it is a
  # real access-point id (fsap- prefix) — never feed a mis-parsed handle to delete-access-point.
  ap="${handle##*:}"
  case "$ap" in
    fsap-*) aws_cmd efs delete-access-point --access-point-id "$ap" >/dev/null 2>&1 || true ;;
  esac
}

test_neuron_cache_pvc_bound() {
  local name rc=0
  resolve_efs_storage_class
  [ -n "${EFS_SC_NAME:-}" ] || return 2   # skip: EFS not enabled on this cluster
  name="neuron-cache-live-$$"
  # Clean up the PV + EFS access point on every exit path (EXIT covers errexit; TERM covers the
  # watchdog's process-group SIGTERM on timeout — see test_reaper_dryrun_job for the rationale).
  # shellcheck disable=SC2064  # set-time expansion: $name is local and gone when EXIT fires post-return
  trap "_cleanup_efs_test_pvc '$NAMESPACE' '$name'" EXIT
  # shellcheck disable=SC2064
  trap "_cleanup_efs_test_pvc '$NAMESPACE' '$name'; exit 143" TERM
  _apply_efs_test_pvc "$NAMESPACE" "$name" "$EFS_SC_NAME"
  kubectl wait --for=jsonpath='{.status.phase}'=Bound "pvc/$name" -n "$NAMESPACE" --timeout=120s || rc=1
  return "$rc"
}

test_neuron_cache_multi_pvc_coexist() {
  local a b rc=0 va vb
  resolve_efs_storage_class
  [ -n "${EFS_SC_NAME:-}" ] || return 2
  a="neuron-cache-a-$$"; b="neuron-cache-b-$$"
  # shellcheck disable=SC2064  # set-time expansion: $a/$b are local and gone when EXIT fires post-return
  trap "_cleanup_efs_test_pvc '$NAMESPACE' '$a'; _cleanup_efs_test_pvc '$NAMESPACE' '$b'" EXIT
  # shellcheck disable=SC2064
  trap "_cleanup_efs_test_pvc '$NAMESPACE' '$a'; _cleanup_efs_test_pvc '$NAMESPACE' '$b'; exit 143" TERM
  _apply_efs_test_pvc "$NAMESPACE" "$a" "$EFS_SC_NAME"
  _apply_efs_test_pvc "$NAMESPACE" "$b" "$EFS_SC_NAME"
  # Both must bind at once: proves per-PVC access points (impossible with a single static PV).
  kubectl wait --for=jsonpath='{.status.phase}'=Bound "pvc/$a" "pvc/$b" -n "$NAMESPACE" --timeout=120s || rc=1
  if [ "$rc" -eq 0 ]; then
    va="$(kubectl get pvc "$a" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')"
    vb="$(kubectl get pvc "$b" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')"
    { [ -n "$va" ] && [ "$va" != "$vb" ]; } || rc=1   # distinct volumes = distinct access points
  fi
  return "$rc"
}
