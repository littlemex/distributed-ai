# gpu-distributed-vllm-ray.yaml.tpl
#
# Multi-node distributed vLLM inference across TWO GPU nodes using Ray + pipeline
# parallelism (PP). This proves the cluster can run a single model sharded across
# separate nodes. EFA is NOT required: cross-node traffic here is Ray/RPC + pipeline
# activations over TCP (pipeline parallel is bandwidth-light vs. tensor parallel).
#
# Topology:
#   - vllm-ray-head   : 1 pod on GPU node A (Ray head + vLLM API server on :8000)
#   - vllm-ray-worker : 1 pod on GPU node B (Ray worker, joins the head)
#   - podAntiAffinity forces the two pods onto DIFFERENT nodes, so Karpenter provisions
#     a second g6e node and the model genuinely spans two machines.
#   - vLLM launches with --pipeline-parallel-size=2 --tensor-parallel-size=1
#     => 1 GPU per node, 2 nodes, model split by layers across the pipeline.
#
# Prerequisites: a GPU accelerator pool (device_plugin="nvidia"), e.g. gpu-training.
#
# Usage:
#   NAMESPACE=<your-namespace>
#   MODEL=Qwen/Qwen2.5-7B-Instruct     # ungated; ~15GB, fits split across 2x L40S
#   sed -e "s/__NAMESPACE__/${NAMESPACE}/g" -e "s#__MODEL__#${MODEL}#g" \
#       gpu-distributed-vllm-ray.yaml.tpl | kubectl apply -f -
#
# Verify:
#   kubectl -n $NAMESPACE rollout status deploy/vllm-ray-head --timeout=20m
#   kubectl -n $NAMESPACE exec deploy/vllm-ray-head -- ray status   # shows 2 nodes / 2 GPUs
#   kubectl -n $NAMESPACE port-forward svc/vllm-ray-head 8000:8000 &
#   curl localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
#     -d '{"model":"__MODEL__","messages":[{"role":"user","content":"Hi"}],"max_tokens":32}'
#
# Image: vllm/vllm-openai:latest ships Ray and the vllm CLI. The head starts a Ray head,
# the worker joins it; once 2 nodes are in the Ray cluster, vLLM is started on the head.
# ─────────────────────────────────────────────────────────────────────────────
apiVersion: v1
kind: ConfigMap
metadata:
  name: vllm-ray-scripts
  namespace: __NAMESPACE__
data:
  # Head: start Ray head (GCS on 6379), wait for all nodes to join, then launch vLLM.
  # --node-ip-address=$POD_IP binds GCS to the routable Pod IP so the worker's Service DNS
  # resolves to a reachable endpoint (relying on hostname resolution can bind to the wrong IP).
  head.sh: |
    #!/bin/bash
    set -euo pipefail
    ray start --head --node-ip-address="${POD_IP}" --port=6379 \
      --dashboard-host=0.0.0.0 --num-gpus=1
    echo "[head] waiting for ${EXPECTED_NODES} Ray nodes to join..."
    for i in $(seq 1 180); do
      alive=$(python3 -c "import ray; ray.init(address='auto'); print(sum(1 for x in ray.nodes() if x['Alive']))" 2>/dev/null || echo 0)
      echo "[head] alive Ray nodes: ${alive}/${EXPECTED_NODES}"
      [ "${alive}" -ge "${EXPECTED_NODES}" ] && break
      sleep 5
    done
    echo "[head] starting vLLM (PP=${EXPECTED_NODES}, TP=1) across the Ray cluster"
    exec vllm serve "${MODEL}" \
      --tensor-parallel-size=1 \
      --pipeline-parallel-size="${EXPECTED_NODES}" \
      --distributed-executor-backend=ray \
      --max-model-len=4096 \
      --gpu-memory-utilization=0.90 \
      --port=8000
  # Worker: join the head's Ray cluster and block. Retry until GCS is actually listening —
  # the Service DNS may resolve before the head's GCS has bound (a brief race at startup).
  worker.sh: |
    #!/bin/bash
    set -uo pipefail
    echo "[worker] joining Ray head at ${HEAD_ADDR}:6379 (node-ip ${POD_IP})"
    until ray start --address="${HEAD_ADDR}:6379" --node-ip-address="${POD_IP}" --num-gpus=1; do
      echo "[worker] GCS not reachable yet; retrying in 5s..."
      sleep 5
    done
    echo "[worker] joined Ray cluster; blocking."
    sleep infinity
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-ray-head
  namespace: __NAMESPACE__
  labels: { app: vllm-ray, role: head }
spec:
  replicas: 1
  selector:
    matchLabels: { app: vllm-ray, role: head }
  template:
    metadata:
      labels: { app: vllm-ray, role: head }
    spec:
      nodeSelector: { node-role: gpu-training }
      tolerations:
        - { key: nvidia.com/gpu,        operator: Exists, effect: NoSchedule }
        - { key: vpc.amazonaws.com/efa, operator: Exists, effect: NoSchedule }
        - { key: capacity-reservation,  operator: Exists, effect: NoSchedule }
      # Force head and worker onto different nodes.
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector: { matchLabels: { app: vllm-ray } }
              topologyKey: kubernetes.io/hostname
      containers:
        - name: vllm
          # Pinned to a ray-bundled tag: vllm/vllm-openai:latest dropped the ray dependency,
          # which multi-node vLLM requires. v0.6.3.post1 ships ray 2.37.0 (verified).
          image: vllm/vllm-openai:v0.6.3.post1
          command: ["/bin/bash", "/scripts/head.sh"]
          env:
            - { name: MODEL, value: "__MODEL__" }
            - { name: EXPECTED_NODES, value: "2" }   # head + 1 worker = pipeline-parallel-size
            - name: POD_IP
              valueFrom: { fieldRef: { fieldPath: status.podIP } }
          ports:
            - { name: http, containerPort: 8000 }
            - { name: ray,  containerPort: 6379 }
          resources:
            limits: { nvidia.com/gpu: "1", memory: 48Gi }
            requests: { cpu: "8", memory: 48Gi }
          # startupProbe absorbs the long Ray-join + model-load window so the kubelet does
          # not kill the head before vLLM is up; readinessProbe then gates Service traffic.
          startupProbe:
            httpGet: { path: /health, port: 8000 }
            periodSeconds: 15
            failureThreshold: 120   # up to ~30 min for join + model load
          readinessProbe:
            httpGet: { path: /health, port: 8000 }
            periodSeconds: 15
            failureThreshold: 4
          volumeMounts:
            - { name: scripts, mountPath: /scripts }
            - { name: shm, mountPath: /dev/shm }
      volumes:
        - { name: scripts, configMap: { name: vllm-ray-scripts } }
        - { name: shm, emptyDir: { medium: Memory, sizeLimit: 8Gi } }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-ray-worker
  namespace: __NAMESPACE__
  labels: { app: vllm-ray, role: worker }
spec:
  replicas: 1
  selector:
    matchLabels: { app: vllm-ray, role: worker }
  template:
    metadata:
      labels: { app: vllm-ray, role: worker }
    spec:
      nodeSelector: { node-role: gpu-training }
      tolerations:
        - { key: nvidia.com/gpu,        operator: Exists, effect: NoSchedule }
        - { key: vpc.amazonaws.com/efa, operator: Exists, effect: NoSchedule }
        - { key: capacity-reservation,  operator: Exists, effect: NoSchedule }
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector: { matchLabels: { app: vllm-ray } }
              topologyKey: kubernetes.io/hostname
      containers:
        - name: vllm
          image: vllm/vllm-openai:v0.6.3.post1
          command: ["/bin/bash", "/scripts/worker.sh"]
          env:
            - { name: HEAD_ADDR, value: "vllm-ray-head.__NAMESPACE__.svc.cluster.local" }
            - name: POD_IP
              valueFrom: { fieldRef: { fieldPath: status.podIP } }
          resources:
            limits: { nvidia.com/gpu: "1", memory: 48Gi }
            requests: { cpu: "8", memory: 48Gi }
          volumeMounts:
            - { name: scripts, mountPath: /scripts }
            - { name: shm, mountPath: /dev/shm }
      volumes:
        - { name: scripts, configMap: { name: vllm-ray-scripts } }
        - { name: shm, emptyDir: { medium: Memory, sizeLimit: 8Gi } }
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-ray-head
  namespace: __NAMESPACE__
  labels: { app: vllm-ray, role: head }
spec:
  # Headless so the worker resolves the head pod directly for Ray GCS traffic.
  clusterIP: None
  # CRITICAL: publish the head's DNS record BEFORE it passes readiness. The head only
  # becomes ready once vLLM is up, but vLLM waits for the worker to join the Ray cluster,
  # and the worker resolves the head via this Service — a deadlock unless not-ready
  # addresses are published during cluster formation.
  publishNotReadyAddresses: true
  selector: { app: vllm-ray, role: head }
  ports:
    - { name: http, port: 8000, targetPort: 8000 }
    - { name: ray,  port: 6379, targetPort: 6379 }
