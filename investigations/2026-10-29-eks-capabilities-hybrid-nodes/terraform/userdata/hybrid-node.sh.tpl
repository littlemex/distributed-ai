#!/bin/bash
# Join this machine to the EKS cluster as a hybrid node using only an SSM hybrid activation.
set -euxo pipefail
exec > >(tee -a /var/log/hybrid-bootstrap.log) 2>&1

# Ubuntu cloud images ship an SSM agent snap registered as an EC2 instance; nodeadm
# installs and registers its own agent with the hybrid activation instead.
snap remove amazon-ssm-agent || true

curl -fsSLo /usr/local/bin/nodeadm https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/amd64/nodeadm
chmod +x /usr/local/bin/nodeadm

nodeadm install ${kubernetes_version} --credential-provider ssm

cat > /etc/nodeadm-config.yaml <<CFG
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${cluster_name}
    region: ${region}
  hybrid:
    ssm:
      activationCode: ${activation_code}
      activationId: ${activation_id}
CFG

nodeadm init -c file:///etc/nodeadm-config.yaml
echo BOOTSTRAP_DONE
