#!/bin/bash
# Run every check of this investigation against an environment built by terraform/,
# and print one [PASS] or [FAIL] line per check with the observed evidence.
#
#   T1  the managed Argo CD deploys a Helm chart onto the on-premises hybrid node
#   T2  the managed Argo CD refuses a non-EKS cluster registered by API URL
#   T3  a second Argo CD, installed by the managed one, deploys to the non-EKS cluster
#   T4  one change on the managed Argo CD reaches both targets
#   T5  a workload deleted by hand on the non-EKS cluster comes back
#   T6  the hybrid node talks to the private cluster endpoint over the private network
set -uo pipefail
: "${AWS_REGION:?}"
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
TF="terraform -chdir=$ROOT/terraform output -raw"
mkdir -p "$ROOT/results"
exec > >(tee "$ROOT/results/verify.log") 2>&1

export CLUSTER_NAME=$($TF cluster_name)
CLUSTER_ARN=$($TF cluster_arn)
export K3S_INSTANCE_ID=$($TF other_instance_id)
export K3S_PRIVATE_IP=$($TF other_private_ip)
export RELAY_INSTANCE_ID=$K3S_INSTANCE_ID
LOCAL_PORT=${LOCAL_PORT:-8443}

K="kubectl --context $CLUSTER_NAME"
ON_K3S="$HERE/ssm-run.sh $K3S_INSTANCE_ID"
FAILED=0
pass() { echo "[PASS] $1: $2"; }
fail() { echo "[FAIL] $1: $2"; FAILED=1; }
wait_for() { # <seconds> <command...>: retry until the command succeeds
  local deadline=$(( $(date +%s) + $1 )); shift
  until "$@" >/dev/null 2>&1; do [ "$(date +%s)" -ge "$deadline" ] && return 1; sleep 5; done
}
app_status() { $K -n "$1" get application "$2" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null; }
app_ok() { [ "$(app_status "$1" "$2")" = Synced/Healthy ]; }

# ── access to the private endpoint ────────────────────────────────────────────
"$HERE/port-forward.sh" >/tmp/ekscap-port-forward.log 2>&1 &
PF=$!
trap 'pkill -P $PF 2>/dev/null; kill $PF 2>/dev/null' EXIT
wait_for 60 nc -z 127.0.0.1 "$LOCAL_PORT" || { echo "port forward did not open"; exit 1; }
wait_for 60 $K get --raw /readyz || { echo "API server not reachable through the port forward"; exit 1; }

# ── hybrid node and its CNI ──────────────────────────────────────────────────
hybrid_node() { $K get nodes -l eks.amazonaws.com/compute-type=hybrid -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
has_hybrid_node() { [ -n "$(hybrid_node)" ]; }
wait_for 900 has_hybrid_node
NODE=$(hybrid_node)
[ -n "$NODE" ] || { fail setup "no hybrid node joined"; exit 1; }
helm upgrade --install cilium oci://public.ecr.aws/eks/cilium/cilium --version 1.18.3-0 \
  --kube-context "$CLUSTER_NAME" -n kube-system -f "$ROOT/k8s/cilium-values.yaml" --wait --timeout 10m >/dev/null
$K wait node "$NODE" --for=condition=Ready --timeout=5m >/dev/null
echo "[INFO] hybrid node $NODE is Ready"

# ── the managed Argo CD sees the hub cluster by its ARN ──────────────────────
$K apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: hub
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
stringData:
  name: hub
  server: $CLUSTER_ARN
  project: default
YAML

# ── T1 ───────────────────────────────────────────────────────────────────────
$K apply -f "$ROOT/k8s/t1-podinfo-onprem.yaml" >/dev/null
if wait_for 300 app_ok argocd podinfo-onprem; then
  PLACEMENT=$($K -n podinfo-onprem get pods -o jsonpath='{range .items[*]}{.spec.nodeName}={.status.podIP} {end}')
  OFF_NODE=$(echo "$PLACEMENT" | tr ' ' '\n' | grep -v "^$NODE=10\.81\." | grep -c . || true)
  REPLY=$($K run t1-curl --rm -i --restart=Never --quiet --image=public.ecr.aws/docker/library/busybox:1.37 \
    --overrides='{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"eks.amazonaws.com/compute-type","operator":"NotIn","values":["hybrid"]}]}]}}}}}' \
    -- wget -qO- -T10 http://podinfo-onprem.podinfo-onprem:9898/ 2>/dev/null | grep -o '"message": "[^"]*"')
  if [ "$OFF_NODE" = 0 ] && [ -n "$REPLY" ]; then
    pass T1 "pods $PLACEMENT; a pod on a cloud node got $REPLY"
  else
    fail T1 "placement=[$PLACEMENT] reply=[$REPLY]"
  fi
else
  fail T1 "Application status $(app_status argocd podinfo-onprem)"
fi

# ── T2 ───────────────────────────────────────────────────────────────────────
"$HERE/register-k3s.sh" argocd >/dev/null
$K apply -f "$ROOT/k8s/t2-podinfo-direct.yaml" >/dev/null
t2_conditions() { $K -n argocd get application podinfo-direct -o jsonpath='{.status.conditions[*].message}'; }
t2_refused() { t2_conditions | grep -q 'server should be specified as a cluster ARN'; }
if wait_for 180 t2_refused; then
  echo "[INFO] T2 conditions: $(t2_conditions)"
  if NAMESPACES=$($ON_K3S "k3s kubectl get namespaces -o name"); then
    echo "$NAMESPACES" | grep -qx 'namespace/podinfo-direct' \
      && fail T2 "refused, but namespace podinfo-direct exists on k3s" \
      || pass T2 "refused with \"server should be specified as a cluster ARN\"; no namespace podinfo-direct on k3s"
  else
    fail T2 "refused, but listing namespaces on k3s failed"
  fi
else
  fail T2 "no refusal; conditions: $(t2_conditions)"
fi
$K -n argocd delete application podinfo-direct --wait=false >/dev/null
$K -n argocd delete secret other-k3s >/dev/null

# ── T3 ───────────────────────────────────────────────────────────────────────
$K apply -f "$ROOT/k8s/t3-tier2-argocd.yaml" >/dev/null
wait_for 600 app_ok argocd tier2-argocd
"$HERE/register-k3s.sh" argocd-edge >/dev/null
k3s_ready() { $ON_K3S "k3s kubectl -n podinfo-other get deploy podinfo-other -o jsonpath='{.status.readyReplicas}' 2>/dev/null" | tr -d '\n'; }
k3s_ready_is() { [ "$(k3s_ready)" = "$1" ]; }
if wait_for 300 app_ok argocd-edge podinfo-other && wait_for 120 k3s_ready_is 1; then
  pass T3 "tier2-argocd $(app_status argocd tier2-argocd), podinfo-other $(app_status argocd-edge podinfo-other), k3s readyReplicas=$(k3s_ready)"
else
  fail T3 "tier2-argocd $(app_status argocd tier2-argocd), podinfo-other $(app_status argocd-edge podinfo-other), k3s readyReplicas=$(k3s_ready)"
fi

# ── T4 ───────────────────────────────────────────────────────────────────────
# Change only the Applications on the managed Argo CD: the on-prem one directly, and
# the k3s one through the argocd-apps values. Done means the new message is served.
T0=$(date +%s)
$K -n argocd patch application podinfo-onprem --type json -p '[
  {"op":"replace","path":"/spec/source/helm/valuesObject/replicaCount","value":3},
  {"op":"replace","path":"/spec/source/helm/valuesObject/ui/message","value":"v2 on-prem"}]' >/dev/null
$K -n argocd patch application tier2-apps --type json -p '[
  {"op":"add","path":"/spec/source/helm/valuesObject/applications/podinfo-other/source/helm/valuesObject/replicaCount","value":2},
  {"op":"replace","path":"/spec/source/helm/valuesObject/applications/podinfo-other/source/helm/valuesObject/ui/message","value":"v2 k3s"}]' >/dev/null
ONPREM_SVC=$($K -n podinfo-onprem get svc podinfo-onprem -o jsonpath='{.spec.clusterIP}')
onprem_done() {
  [ "$($K -n podinfo-onprem get deploy podinfo-onprem -o jsonpath='{.status.readyReplicas}/{.status.updatedReplicas}/{.status.replicas}')" = 3/3/3 ] &&
  "$HERE/ssm-run.sh" "$NODE" "curl -s $ONPREM_SVC:9898" | grep -q '"message": "v2 on-prem"'
}
k3s_done() {
  k3s_ready_is 2 &&
  $ON_K3S "curl -s \$(k3s kubectl -n podinfo-other get svc podinfo-other -o jsonpath='{.spec.clusterIP}'):9898" | grep -q '"message": "v2 k3s"'
}
wait_for 300 onprem_done; T_ONPREM=$(( $(date +%s)-T0 ))
wait_for 300 k3s_done; T_K3S=$(( $(date +%s)-T0 ))
if onprem_done && k3s_done; then
  pass T4 "on-prem: 3 ready replicas serving \"v2 on-prem\" within ${T_ONPREM}s; k3s: 2 ready replicas serving \"v2 k3s\" within ${T_K3S}s (from the first patch, polling included)"
else
  fail T4 "on-prem done=$(onprem_done && echo yes || echo no), k3s done=$(k3s_done && echo yes || echo no)"
fi

# ── T5 ───────────────────────────────────────────────────────────────────────
# Both times come from the k3s machine's clock: when the delete was issued, and the
# creationTimestamp of the Deployment the second Argo CD put back.
DELETED_AT=$($ON_K3S "date -u +%FT%TZ; k3s kubectl -n podinfo-other delete deploy podinfo-other >/dev/null" | head -1)
created_after() { C=$($ON_K3S "k3s kubectl -n podinfo-other get deploy podinfo-other -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null" | tr -d '\n'); [ -n "$C" ] && [[ "$C" > "$DELETED_AT" || "$C" == "$DELETED_AT" ]]; }
if [ -n "$DELETED_AT" ] && wait_for 300 created_after && wait_for 120 k3s_ready_is 2; then
  pass T5 "deleted at $DELETED_AT, recreated at $C (k3s clock, UTC), 2 ready replicas"
else
  fail T5 "not recreated after [$DELETED_AT]"
fi

# ── T6 ───────────────────────────────────────────────────────────────────────
PEERS=$("$HERE/ssm-run.sh" "$NODE" "ss -tnp | grep kubelet | awk '\$5 ~ /:443\$/ {print \$5}' | sort -u" | tr '\n' ' ')
if [ -n "$PEERS" ] && ! echo "$PEERS" | tr ' ' '\n' | grep -v '^$' | grep -vq '^10\.0\.'; then
  pass T6 "kubelet connects to $PEERS (hub VPC private addresses)"
else
  fail T6 "kubelet connects to [$PEERS]"
fi

exit $FAILED
