#!/bin/bash
# Register the k3s cluster as an Argo CD cluster secret in the given namespace of the
# hub cluster, using a ServiceAccount token created on k3s. The token goes straight
# from SSM output into kubectl and is never written to disk.
# usage: register-k3s.sh <argocd-namespace-on-hub>
set -euo pipefail
: "${AWS_REGION:?}" "${CLUSTER_NAME:?}" "${K3S_INSTANCE_ID:?}" "${K3S_PRIVATE_IP:?}"
NS=$1
HERE=$(cd "$(dirname "$0")" && pwd)
run() { "$HERE/ssm-run.sh" "$K3S_INSTANCE_ID" "$@"; }

run "echo $(base64 < "$HERE/../k8s/k3s-deployer-sa.yaml" | tr -d '\n') | base64 -d | k3s kubectl apply -f -" >/dev/null
TOKEN=$(run "k3s kubectl -n kube-system get secret argocd-deployer-token -o jsonpath='{.data.token}' | base64 -d" | tr -d '\n') \
CA=$(run "k3s kubectl -n kube-system get secret argocd-deployer-token -o jsonpath='{.data.ca\.crt}'" | tr -d '\n') \
NS=$NS SERVER="https://$K3S_PRIVATE_IP:6443" python3 -c '
import json, os
print(json.dumps({
  "apiVersion": "v1", "kind": "Secret",
  "metadata": {"name": "other-k3s", "namespace": os.environ["NS"],
               "labels": {"argocd.argoproj.io/secret-type": "cluster"}},
  "stringData": {"name": "other-k3s", "server": os.environ["SERVER"],
                 "config": json.dumps({"bearerToken": os.environ["TOKEN"],
                                       "tlsClientConfig": {"caData": os.environ["CA"]}})}}))' \
| kubectl --context "$CLUSTER_NAME" apply -f -
