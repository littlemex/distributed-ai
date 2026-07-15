# neuron-serving-vllm.yaml.tpl
#
# vLLM (NxD Inference backend) OpenAI-compatible server on a single trn2.48xlarge
# (16 Trainium2 devices). Deploys onto the "trn2-serving" accelerator pool provisioned by
# Karpenter (see var.accelerator_pools). The Neuron device plugin advertises
# aws.amazon.com/neuron; requesting all 16 devices places the pod on one whole trn2 node.
#
# Prerequisites (from the Terraform stack):
#   - An accelerator pool with device_plugin="neuron" (e.g. trn2-serving) is defined.
#   - neuron-addons.tf installed the Neuron device plugin. For tensor-parallel serving
#     across many devices, set var.neuron_enable_scheduler=true (contiguous device IDs).
#   - A PVC "neuron-cache-pvc" (EFS/EBS) exists to persist compiled NEFF artifacts, so the
#     multi-minute first-run compilation is not repeated on every restart.
#
# Usage:
#   NAMESPACE=<your-namespace>
#   MODEL=meta-llama/Llama-3.1-8B-Instruct
#   sed -e "s/__NAMESPACE__/${NAMESPACE}/g" -e "s#__MODEL__#${MODEL}#g" \
#       neuron-serving-vllm.yaml.tpl | kubectl apply -f -
#
# Verify:
#   kubectl -n $NAMESPACE logs -f deploy/neuron-vllm       # watch NEFF compilation, then "Uvicorn running"
#   kubectl -n $NAMESPACE port-forward svc/neuron-vllm 8000:8000 &
#   curl localhost:8000/v1/models
#   curl localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
#     -d '{"model":"__MODEL__","messages":[{"role":"user","content":"Hello from Trainium"}]}'
#
# Image: HuggingFace vLLM Inference NeuronX DLC. Confirm the exact tag/region with
#   aws ecr describe-images --registry-id 763104351884 \
#     --repository-name huggingface-vllm-inference-neuronx --region <region>
# and substitute below. The pinned tag here is a known-good reference; newer SDK tags exist.
# ─────────────────────────────────────────────────────────────────────────────
apiVersion: apps/v1
kind: Deployment
metadata:
  name: neuron-vllm
  namespace: __NAMESPACE__
  labels:
    app: neuron-vllm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: neuron-vllm
  template:
    metadata:
      labels:
        app: neuron-vllm
    spec:
      # Land on the Neuron (Trainium) accelerator pool.
      nodeSelector:
        node-role: trn2-serving

      # The Neuron device plugin taints nodes aws.amazon.com/neuron=true:NoSchedule; the
      # EFA taint and the Capacity Block taint (value rotates per reservation) also apply.
      tolerations:
        - { key: aws.amazon.com/neuron,  operator: Exists, effect: NoSchedule }
        - { key: vpc.amazonaws.com/efa,  operator: Exists, effect: NoSchedule }
        - { key: capacity-reservation,   operator: Exists, effect: NoSchedule }

      containers:
        - name: vllm
          image: 763104351884.dkr.ecr.us-east-2.amazonaws.com/huggingface-vllm-inference-neuronx:0.11.0-optimum0.4.5-neuronx-py310-sdk2.26.1-ubuntu22.04
          command: ["python", "-m", "vllm.entrypoints.openai.api_server"]
          args:
            - --model=__MODEL__
            - --tensor-parallel-size=32   # 16 devices x LNC=2 -> 32 logical NeuronCores
            - --max-num-seqs=4
            - --max-model-len=4096
            - --device=neuron
            - --port=8000
          env:
            - { name: VLLM_NEURON_FRAMEWORK, value: "neuronx-distributed-inference" }
            # Persist compiled artifacts so restarts skip recompilation.
            - { name: NEURON_COMPILED_ARTIFACTS, value: "/mnt/neuron-cache" }
            # HF token for gated models (create the secret separately; optional otherwise).
            - name: HF_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-token
                  key: token
                  optional: true
          ports:
            - { name: http, containerPort: 8000 }
          # NOTE: no hugepages-2Mi request. Karpenter does not size new nodes against
          # hugepages, so requesting it on a provisioning-triggering pod makes Karpenter
          # report "no instance type has enough resources" and skip the NodeClaim.
          # (Verified on trn2.48xlarge — Neuron/EFA serving does not need hugepages here.)
          resources:
            limits:
              aws.amazon.com/neuron: "16"   # all 16 Trainium2 devices on trn2.48xlarge
              vpc.amazonaws.com/efa: "16"
              memory: 512Gi
            requests:
              aws.amazon.com/neuron: "16"
              cpu: "48"
              memory: 512Gi
          readinessProbe:
            httpGet: { path: /health, port: 8000 }
            # First run compiles the model to NEFF (can take many minutes); start late.
            initialDelaySeconds: 300
            periodSeconds: 15
            failureThreshold: 120
          volumeMounts:
            - { name: neuron-cache, mountPath: /mnt/neuron-cache }
            - { name: shm, mountPath: /dev/shm }

      volumes:
        - name: neuron-cache
          persistentVolumeClaim:
            claimName: neuron-cache-pvc
        - name: shm
          emptyDir: { medium: Memory, sizeLimit: 8Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: neuron-vllm
  namespace: __NAMESPACE__
  labels:
    app: neuron-vllm
spec:
  selector:
    app: neuron-vllm
  ports:
    - { name: http, port: 8000, targetPort: 8000 }
