#!/bin/bash
# A plain, non-EKS Kubernetes cluster standing in for AKS / GKE.
set -euxo pipefail
exec > >(tee -a /var/log/k3s-bootstrap.log) 2>&1

TOKEN=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
PRIVATE_IP=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -s - server \
  --tls-san "$PRIVATE_IP" --write-kubeconfig-mode 0600 --disable traefik
echo BOOTSTRAP_DONE
