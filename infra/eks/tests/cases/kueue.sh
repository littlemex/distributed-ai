#!/usr/bin/env bash
# Advanced03 end to end: run the SAME workshop scenario (kueue-reference template + charts/experiments
# trainjobTrain.queueName) the book documents — deploy (submit 3 TrainJobs under a 1-job quota,
# asserting the quota is never exceeded) -> verify (each job's own output, 0 pending workloads) ->
# teardown. This is the live counterpart to the static chart-contract checks on trainjobTrain.

test_kueue_job_scheduling() {
  local sc="$SCRIPT_DIR/scenarios/advanced03-kueue-job-scheduling" image
  resolve_gpu_nodepool
  [ -n "$GPU_NODEPOOL" ] || return 2   # SKIP: no NVIDIA pool derived
  image="$(tf_out ddp_sample_ecr_url)"
  [ -n "$image" ] || return 2          # SKIP: ddp-sample image not built on this cluster (Basic02)
  image="${image}:v1"
  # shellcheck disable=SC2064
  trap "NAMESPACE='$NAMESPACE' NODE_ROLE='$GPU_NODEPOOL' bash '$sc/teardown.sh' >/dev/null 2>&1 || true" EXIT
  # shellcheck disable=SC2064
  trap "NAMESPACE='$NAMESPACE' NODE_ROLE='$GPU_NODEPOOL' bash '$sc/teardown.sh' >/dev/null 2>&1 || true; exit 143" TERM
  NAMESPACE="$NAMESPACE" NODE_ROLE="$GPU_NODEPOOL" IMAGE="$image" bash "$sc/deploy.sh" || return 1
  NAMESPACE="$NAMESPACE" NODE_ROLE="$GPU_NODEPOOL" bash "$sc/verify.sh" || return 1
}
