#!/usr/bin/env bash
# Advanced03 — deploy.sh already waited for all three TrainJobs to reach Complete while asserting the
# quota was never exceeded; this checks the result each of those three runs actually produced: rank 0
# finished its three epochs, and each wrote to its own outputSubdir rather than resuming another
# job's snapshot (the failure mode the chapter's step 4 warns about).
set -euo pipefail
ns="${NAMESPACE:?set NAMESPACE}"
role="${NODE_ROLE:?set NODE_ROLE}"

for n in ddp-trainjob-a ddp-trainjob-b ddp-trainjob-c; do
  suffix="${n##*-}"
  log="$(kubectl -n "$ns" logs -l "jobset.sigs.k8s.io/jobset-name=$n,batch.kubernetes.io/job-completion-index=0" --tail=-1)"
  case "$log" in
    *"trainjob-$role-$suffix/snapshot.pt"*"done"*) ;;
    *) echo "=== $n log ===" >&2; printf '%s\n' "$log" >&2
       echo "$n: expected its own outputSubdir (trainjob-$role-$suffix) and a final 'done' line" >&2
       exit 1 ;;
  esac
done

pending="$(kubectl get clusterqueue "${role}-cq" -o jsonpath='{.status.pendingWorkloads}' 2>/dev/null || true)"
[ -z "$pending" ] && pending=0
[ "$pending" -eq 0 ] || { echo "clusterqueue ${role}-cq still has $pending pending workloads" >&2; exit 1; }

echo "advanced03 kueue scenario ok: 3/3 TrainJobs complete, 0 pending workloads"
