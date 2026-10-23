#!/usr/bin/env bash
# Advanced03 — the chapter's own step 6, in order: delete the three TrainJobs, then the
# LocalQueue/ClusterQueue/ResourceFlavor the reference template created, then drop the namespace's
# opt-in label. Not `-e`: a run that failed partway through deploy.sh may not have created everything
# below, and a swallowed failure here must not leave the namespace permanently opted into Kueue for
# every other chapter that reuses it (the same reason the GPU-serving twin is not `-e`).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
eks_root="$(cd "$here/../../.." && pwd)"
ns="${NAMESPACE:?set NAMESPACE}"
role="${NODE_ROLE:-placeholder}"

kubectl -n "$ns" delete trainjob ddp-trainjob-a ddp-trainjob-b ddp-trainjob-c --ignore-not-found --wait=true --timeout=60s

sed -e "s/__NAMESPACE__/$ns/g" -e "s/__NODEPOOL_NAME__/$role/g" -e "s/__GPU_QUOTA__/0/g" \
  "$eks_root/manifests/kueue-reference/queue.yaml.tmpl" 2>/dev/null \
  | kubectl delete --ignore-not-found -f - 2>/dev/null
# Label-based fallback, independent of the template rendering above, for the same reason the GPU
# serving twin keeps one: a broken template must not leave these cluster-scoped objects behind.
kubectl delete localqueue -n "$ns" "$role" --ignore-not-found
kubectl delete clusterqueue "${role}-cq" --ignore-not-found
kubectl delete resourceflavor "$role" --ignore-not-found

kubectl label namespace "$ns" managed-by-kueue- 2>/dev/null || true
