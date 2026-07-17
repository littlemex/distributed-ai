# neuron-probe-pod.yaml.tpl
#
# Single-node Trainium/Neuron sanity probe — confirms that:
#   1. The pod lands on a Neuron node (trn2 accelerator pool) via the device plugin.
#   2. The Neuron device plugin advertises aws.amazon.com/neuron (request succeeds).
#   3. neuron-ls enumerates the Trainium2 devices/NeuronCores on the node.
#
# Usage:
#   NAMESPACE=<your-namespace>
#   sed "s/__NAMESPACE__/${NAMESPACE}/g" neuron-probe-pod.yaml.tpl | kubectl apply -f -
#
# Verify inside the pod:
#   kubectl -n $NAMESPACE exec neuron-probe -- neuron-ls
#   # trn2.48xlarge: 16 Trainium2 devices (neuron-ls shows device/core topology).
#   kubectl -n $NAMESPACE exec neuron-probe -- fi_info -p efa -t FI_EP_RDM | grep -c provider
#   # EFA present once the trn2 EC2NodeClass attached efa-only ENIs.
#
# Image: PyTorch Inference NeuronX DLC ships neuron-ls / aws-neuronx-tools. Confirm the
# exact tag/region with `aws ecr describe-images --registry-id 763104351884
#   --repository-name pytorch-inference-neuronx --region <region>` and substitute.
# ─────────────────────────────────────────────────────────────────────────────
apiVersion: v1
kind: Pod
metadata:
  name: neuron-probe
  namespace: __NAMESPACE__
  labels:
    app: neuron-probe
spec:
  restartPolicy: Never

  # Pin to the Trainium accelerator pool.
  nodeSelector:
    node-role: trn2-serving

  # Neuron device-plugin taint + EFA taint + Capacity Block taint (value rotates per CB).
  tolerations:
    - { key: aws.amazon.com/neuron, operator: Exists, effect: NoSchedule }
    - { key: vpc.amazonaws.com/efa, operator: Exists, effect: NoSchedule }
    - { key: capacity-reservation,  operator: Exists, effect: NoSchedule }

  containers:
    - name: probe
      image: 763104351884.dkr.ecr.us-east-2.amazonaws.com/pytorch-inference-neuronx:2.9.0-neuronx-py312-sdk2.30.0-ubuntu24.04
      command: ["sleep", "3600"]
      # NOTE: do NOT request hugepages-2Mi here. Karpenter does not treat hugepages as a
      # schedulable well-known resource when sizing a new node, so a hugepages request on a
      # pod that triggers provisioning makes Karpenter report "no instance type has enough
      # resources" and it never creates the NodeClaim. The Neuron/EFA stack does not need
      # hugepages for this probe. (Verified on trn2.48xlarge.)
      resources:
        limits:
          aws.amazon.com/neuron: "1"   # minimal claim: one Neuron device
          vpc.amazonaws.com/efa: "1"
          memory: 16Gi
        requests:
          cpu: "4"
          memory: 16Gi
      volumeMounts:
        - { name: shm, mountPath: /dev/shm }

  volumes:
    - name: shm
      emptyDir: { medium: Memory, sizeLimit: 8Gi }
