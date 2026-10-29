#!/bin/bash
# The cluster endpoint is private. Reach it from a laptop through an SSM port forward
# on the k3s machine, which the Transit Gateway routes to the hub network, and point
# a kube context at 127.0.0.1 while still verifying the real server name.
set -euo pipefail
: "${AWS_REGION:?}" "${CLUSTER_NAME:?}" "${RELAY_INSTANCE_ID:?}"
LOCAL_PORT=${LOCAL_PORT:-8443}

ENDPOINT_HOST=$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --query cluster.endpoint --output text | sed 's#https://##')
CLUSTER_ARN=$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --query cluster.arn --output text)
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME" >/dev/null
kubectl config set-cluster "$CLUSTER_ARN" --server "https://127.0.0.1:$LOCAL_PORT" --tls-server-name "$ENDPOINT_HOST" >/dev/null

exec aws ssm start-session --region "$AWS_REGION" --target "$RELAY_INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$ENDPOINT_HOST,portNumber=443,localPortNumber=$LOCAL_PORT"
