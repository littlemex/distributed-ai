#!/usr/bin/env bash
# Advanced03 — the SAME commands the chapter documents: opt the namespace into Kueue, render the
# reference ClusterQueue/ResourceFlavor/LocalQueue with this cluster's own GPU pool and a quota that
# fits exactly one of the three TrainJobs, submit all three at once, and assert the thing the chapter
# is actually about — that the ClusterQueue's nvidia.com/gpu usage never exceeds GPU_QUOTA while the
# three are in flight, not just that they all eventually finish (which a scheduler with no queue at
# all would also do).
#
# Env: NAMESPACE, NODE_ROLE (the accelerator_pools key / NodePool name — same meaning as the GPU
# serving scenario's NODE_ROLE), IMAGE (ddp-sample ECR URL incl. tag). CHART, GPU_QUOTA,
# ROLLOUT_TIMEOUT optional. RUN_ID, when set, goes into each outputSubdir so a rerun on the same
# filesystem starts fresh instead of resuming the previous run's snapshot; verify.sh reads it too.
# The jobs mount the PVC named in the shared torch-distributed-eks ClusterTrainingRuntime
# (shared-claim), so NAMESPACE must already have a PVC by that name.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
eks_root="$(cd "$here/../../.." && pwd)"
chart="${CHART:-$eks_root/charts/experiments}"
ns="${NAMESPACE:?set NAMESPACE}"
role="${NODE_ROLE:?set NODE_ROLE (the GPU pool key)}"
image="${IMAGE:?set IMAGE (ddp-sample ECR URL:tag)}"
run_prefix="${RUN_ID:+${RUN_ID}-}"
quota="${GPU_QUOTA:-2}"   # 2 == exactly one job's worth (numNodes=2 x gpu.count=1), the chapter's own number
rollout_timeout="${ROLLOUT_TIMEOUT:-15m}"

names=(ddp-trainjob-a ddp-trainjob-b ddp-trainjob-c)

# Step 3 of the chapter: opt the namespace in, then render the reference queue template.
kubectl label namespace "$ns" managed-by-kueue=true --overwrite
sed -e "s/__NAMESPACE__/$ns/g" -e "s/__NODEPOOL_NAME__/$role/g" -e "s/__GPU_QUOTA__/$quota/g" \
  "$eks_root/manifests/kueue-reference/queue.yaml.tmpl" | kubectl apply -f -

# Step 4: submit all three at once, each its own TrainJob name, queue-name label, and output
# subdirectory (so ddp.py never resumes from another job's snapshot — see values.yaml). The chart
# also renders the shared torch-distributed-eks ClusterTrainingRuntime; -l applies only the
# queue-labelled TrainJob, as the chapter does, so the run never rewrites the runtime other
# chapters use.
helm dependency build "$chart" 2>/dev/null || helm dependency update "$chart"
for n in "${names[@]}"; do
  helm template exp "$chart" -f "$here/values.yaml" --set namespace="$ns" \
    --set trainjobTrain.image="$image" --set trainjobTrain.nodeRole="$role" \
    --set trainjobTrain.name="$n" --set trainjobTrain.queueName="$role" \
    --set trainjobTrain.outputSubdir="trainjob-$role-${run_prefix}${n##*-}" \
    --set sharedStorage.existingClaimName=shared-claim \
  | kubectl apply -l kueue.x-k8s.io/queue-name="$role" -f -
done

# The chapter's central claim, checked while it is still checkable: poll the ClusterQueue's own
# usage counter throughout the run (not just its final value, which a queue that let everything
# through immediately would also show as 0 once all three finish) and fail the instant it is seen
# over quota. This is the only point in the scenario that can tell "Kueue held the excess" apart
# from "the cluster happened to have capacity for all three at once".
cq="${role}-cq"
deadline=$((SECONDS + 900))
max_seen=0
while [ "$SECONDS" -lt "$deadline" ]; do
  usage="$(kubectl get clusterqueue "$cq" -o jsonpath='{.status.flavorsUsage[0].resources[?(@.name=="nvidia.com/gpu")].total}' 2>/dev/null || true)"
  [ -n "$usage" ] || usage=0
  [ "$usage" -gt "$max_seen" ] 2>/dev/null && max_seen="$usage"
  if [ "$usage" -gt "$quota" ] 2>/dev/null; then
    echo "ClusterQueue $cq admitted $usage nvidia.com/gpu against a quota of $quota" >&2
    exit 1
  fi
  done_count=0
  for n in "${names[@]}"; do
    state="$(kubectl -n "$ns" get trainjob "$n" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    [ "$state" = "True" ] && done_count=$((done_count + 1))
  done
  [ "$done_count" -eq "${#names[@]}" ] && break
  sleep 5
done
for n in "${names[@]}"; do
  state="$(kubectl -n "$ns" get trainjob "$n" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
  [ "$state" = "True" ] || { echo "$n did not reach Complete within the poll deadline" >&2; exit 1; }
done
echo "max nvidia.com/gpu usage observed on $cq: $max_seen (quota $quota)"
# rollout_timeout is accepted for parity with the other scenarios' deploy.sh signature even though
# the polling loop above (not `kubectl rollout status`, which TrainJob has no analogue of) is what
# actually waits.
: "$rollout_timeout"
