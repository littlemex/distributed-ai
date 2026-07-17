# gpu-serving-vllm.yaml.tpl
#
# vLLM OpenAI-compatible server on the GPU accelerator pool (NVIDIA). Counterpart to
# neuron-serving-vllm.yaml.tpl — same API surface, GPU backend. Verified on g6e.12xlarge
# (L40S x4) with a small ungated model so it works without an HF token.
#
# Prerequisites (from the Terraform stack):
#   - An accelerator pool with device_plugin="nvidia" (e.g. gpu-training).
#   - gpu-addons.tf installed the NVIDIA GPU Operator (advertises nvidia.com/gpu).
#
# Usage:
#   NAMESPACE=<your-namespace>
#   MODEL=Qwen/Qwen2.5-0.5B-Instruct     # ungated, tiny; fits one L40S
#   sed -e "s/__NAMESPACE__/${NAMESPACE}/g" -e "s#__MODEL__#${MODEL}#g" \
#       gpu-serving-vllm.yaml.tpl | kubectl apply -f -
#
# Verify:
#   kubectl -n $NAMESPACE rollout status deploy/gpu-vllm --timeout=15m
#   kubectl -n $NAMESPACE port-forward svc/gpu-vllm 8000:8000 &
#   curl localhost:8000/v1/models
#   curl localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
#     -d '{"model":"__MODEL__","messages":[{"role":"user","content":"Hello from L40S"}]}'
# ─────────────────────────────────────────────────────────────────────────────
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gpu-vllm
  namespace: __NAMESPACE__
  labels:
    app: gpu-vllm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gpu-vllm
  template:
    metadata:
      labels:
        app: gpu-vllm
    spec:
      # Land on the GPU accelerator pool.
      nodeSelector:
        node-role: gpu-training

      # GPU/EFA taints (capacity-reservation value rotates per CB → operator: Exists).
      tolerations:
        - { key: nvidia.com/gpu,        operator: Exists, effect: NoSchedule }
        - { key: vpc.amazonaws.com/efa, operator: Exists, effect: NoSchedule }
        - { key: capacity-reservation,  operator: Exists, effect: NoSchedule }

      containers:
        - name: vllm
          image: vllm/vllm-openai:latest
          args:
            - --model=__MODEL__
            - --tensor-parallel-size=1
            - --max-model-len=4096
            - --gpu-memory-utilization=0.85
            - --port=8000
          env:
            # HF token for gated models (optional; ungated models need no token).
            - name: HF_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-token
                  key: token
                  optional: true
          ports:
            - { name: http, containerPort: 8000 }
          resources:
            limits:
              nvidia.com/gpu: "1"
              memory: 32Gi
            requests:
              cpu: "8"
              memory: 32Gi
          readinessProbe:
            httpGet: { path: /health, port: 8000 }
            initialDelaySeconds: 60
            periodSeconds: 10
            failureThreshold: 90
          volumeMounts:
            - { name: shm, mountPath: /dev/shm }

      volumes:
        - name: shm
          emptyDir: { medium: Memory, sizeLimit: 8Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: gpu-vllm
  namespace: __NAMESPACE__
  labels:
    app: gpu-vllm
spec:
  selector:
    app: gpu-vllm
  ports:
    - { name: http, port: 8000, targetPort: 8000 }
