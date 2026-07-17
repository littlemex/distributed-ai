# nccl-test-sshd-pods.yaml.tpl
#
# Two-node × 8-GPU NCCL bench pods with persistent sshd on port 2222.
#
# Topology: 2 pods on 2 different B300 nodes (podAntiAffinity by hostname).
#            Each pod requests all 8 GPUs and all 16 EFA ENIs of its node,
#            matching p5en.48xlarge (EFA=16, GPU=8, H200) facts.
#            Ref: VERIFIED_FACTS.md — p5en.48xlarge: EFA=16, GPU=8.
#
# sshd note: sshd MUST be the pod's PID-1 subprocess (started from `command`).
# Starting it via `kubectl exec` causes SIGTERM on exec exit (exit 143).
# nohup/setsid do NOT protect against this; only embedding in `command` works.
# Ref: CLUSTER-GUIDE.md §8.2; investigations/gpudirect-rdma-demo/manifests/11-two-nodes-sshd.yaml.
#
# Port: 2222 (hostNetwork=true; port 22 is the node's real sshd).
#
# Usage:
#   NAMESPACE=<your-namespace>
#   sed "s/__NAMESPACE__/${NAMESPACE}/g" nccl-test-sshd-pods.yaml.tpl \
#     | kubectl apply -f -
#
# After pods reach Running, distribute SSH keys:
#   NS=<your-namespace>
#   # Generate key on server, copy public key to authorized_keys on both pods.
#   kubectl -n $NS exec nccl-server -- bash -lc \
#     '[ -f /root/.ssh/id_rsa ] || ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa -q; \
#      cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys'
#   PRIV=$(kubectl -n $NS exec nccl-server -- bash -lc 'base64 -w0 < /root/.ssh/id_rsa')
#   PUB=$(kubectl -n $NS exec nccl-server -- bash -lc 'cat /root/.ssh/id_rsa.pub')
#   kubectl -n $NS exec nccl-client -- bash -lc \
#     "echo '$PRIV' | base64 -d > /root/.ssh/id_rsa && chmod 600 /root/.ssh/id_rsa; \
#      echo '$PUB' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
#
# Then run mpirun from the server pod (substitute real node IPs):
#   SERVER_IP=<server-node-ip>
#   CLIENT_IP=<client-node-ip>
#   kubectl -n $NS exec nccl-server -- bash -lc "
#     export PATH=/opt/amazon/openmpi/bin:/opt/amazon/efa/bin:\$PATH
#     export LD_LIBRARY_PATH=/opt/amazon/efa/lib:/opt/amazon/openmpi/lib:/usr/local/cuda/lib64:\$LD_LIBRARY_PATH
#     mpirun --allow-run-as-root -np 16 -N 8 \
#       -H ${SERVER_IP}:8,${CLIENT_IP}:8 \
#       --mca plm_rsh_args '-p 2222' \
#       -x LD_LIBRARY_PATH -x PATH \
#       -x FI_PROVIDER=efa -x FI_EFA_USE_DEVICE_RDMA=1 -x FI_EFA_FORK_SAFE=1 \
#       -x NCCL_SOCKET_IFNAME='^lo,docker,veth' -x NCCL_DEBUG=INFO \
#       /opt/nccl-tests/build/all_reduce_perf -b 8 -e 1G -f 2 -g 1"
#
# Expected busbw (B300 2-node 16 GPU, 1 GB msg): ~514 GB/s.
# Confirm EFA is active: log line "NET/OFI Selected provider is efa ... Using transport protocol RDMA".
# Ref: CLUSTER-GUIDE.md §8.3.
# ─────────────────────────────────────────────────────────────────────────────
---
apiVersion: v1
kind: Pod
metadata:
  name: nccl-server
  namespace: __NAMESPACE__
  labels:
    app: nccl-bench
    role: server
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  restartPolicy: Never

  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-B300-SXM6-AC

  # Spread the two pods onto different physical nodes so inter-node EFA is exercised.
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels: { app: nccl-bench }
          topologyKey: kubernetes.io/hostname

  # All five B300 taints.  capacity-reservation rotates per CB; Exists is mandatory.
  tolerations:
    - { key: nvidia.com/gpu,                          operator: Exists, effect: NoSchedule }
    - { key: vpc.amazonaws.com/efa,                   operator: Exists, effect: NoSchedule }
    - { key: workload,                                 operator: Equal,  value: bench, effect: NoSchedule }
    - { key: capacity-reservation,                    operator: Exists, effect: NoSchedule }
    - { key: sagemaker.amazonaws.com/node-health-status, operator: Equal, value: Schedulable, effect: NoSchedule }

  containers:
    - name: bench
      image: public.ecr.aws/hpc-cloud/nccl-tests:latest

      # sshd launched as PID-1 subordinate process; keeps the container alive.
      # Port 2222 avoids collision with the node's own sshd on port 22.
      # StrictHostKeyChecking=no in /root/.ssh/config prevents mpirun interactive prompts.
      # Ref: CLUSTER-GUIDE.md §8.2.
      command:
        - bash
        - -lc
        - |
          mkdir -p /run/sshd /root/.ssh
          chmod 700 /root/.ssh
          ssh-keygen -A
          printf 'StrictHostKeyChecking no\nUserKnownHostsFile /dev/null\n' > /root/.ssh/config
          chmod 600 /root/.ssh/config
          /usr/sbin/sshd -p 2222
          sleep 7200

      securityContext:
        privileged: true   # Required for EFA device access and /dev/gdrdrv.

      env:
        - { name: FI_PROVIDER,            value: "efa" }
        - { name: FI_EFA_USE_DEVICE_RDMA, value: "1" }
        - { name: FI_EFA_FORK_SAFE,       value: "1" }
        # Exclusion prefix "^": EFA interfaces are not named predictably, so
        # positive matching hides them and causes TCP fallback (~28x slower).
        # Ref: CLUSTER-GUIDE.md §2, §9 "NCCL/通信が異常に遅い".
        - { name: NCCL_SOCKET_IFNAME,     value: "^lo,docker,veth" }
        - { name: NCCL_DEBUG,             value: "INFO" }

      resources:
        limits:
          nvidia.com/gpu:        "8"     # Full node: 8 H200 GPUs (p5en.48xlarge).
          vpc.amazonaws.com/efa: "16"    # Full node: 16 EFA ENIs (p5en.48xlarge).
          hugepages-2Mi:         8Gi     # RDMA memory registration requirement.
          memory:                128Gi
        requests:
          cpu:           "16"
          memory:        128Gi
          hugepages-2Mi: 8Gi

      volumeMounts:
        - { name: gdrdrv, mountPath: /dev/gdrdrv }
        - { name: shm,    mountPath: /dev/shm }

  volumes:
    - { name: gdrdrv, hostPath: { path: /dev/gdrdrv, type: CharDevice } }
    - { name: shm,    emptyDir: { medium: Memory, sizeLimit: 16Gi } }
---
apiVersion: v1
kind: Pod
metadata:
  name: nccl-client
  namespace: __NAMESPACE__
  labels:
    app: nccl-bench
    role: client
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  restartPolicy: Never

  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-B300-SXM6-AC

  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels: { app: nccl-bench }
          topologyKey: kubernetes.io/hostname

  tolerations:
    - { key: nvidia.com/gpu,                          operator: Exists, effect: NoSchedule }
    - { key: vpc.amazonaws.com/efa,                   operator: Exists, effect: NoSchedule }
    - { key: workload,                                 operator: Equal,  value: bench, effect: NoSchedule }
    - { key: capacity-reservation,                    operator: Exists, effect: NoSchedule }
    - { key: sagemaker.amazonaws.com/node-health-status, operator: Equal, value: Schedulable, effect: NoSchedule }

  containers:
    - name: bench
      image: public.ecr.aws/hpc-cloud/nccl-tests:latest

      command:
        - bash
        - -lc
        - |
          mkdir -p /run/sshd /root/.ssh
          chmod 700 /root/.ssh
          ssh-keygen -A
          printf 'StrictHostKeyChecking no\nUserKnownHostsFile /dev/null\n' > /root/.ssh/config
          chmod 600 /root/.ssh/config
          /usr/sbin/sshd -p 2222
          sleep 7200

      securityContext:
        privileged: true

      env:
        - { name: FI_PROVIDER,            value: "efa" }
        - { name: FI_EFA_USE_DEVICE_RDMA, value: "1" }
        - { name: FI_EFA_FORK_SAFE,       value: "1" }
        - { name: NCCL_SOCKET_IFNAME,     value: "^lo,docker,veth" }
        - { name: NCCL_DEBUG,             value: "INFO" }

      resources:
        limits:
          nvidia.com/gpu:        "8"
          vpc.amazonaws.com/efa: "16"
          hugepages-2Mi:         8Gi
          memory:                128Gi
        requests:
          cpu:           "16"
          memory:        128Gi
          hugepages-2Mi: 8Gi

      volumeMounts:
        - { name: gdrdrv, mountPath: /dev/gdrdrv }
        - { name: shm,    mountPath: /dev/shm }

  volumes:
    - { name: gdrdrv, hostPath: { path: /dev/gdrdrv, type: CharDevice } }
    - { name: shm,    emptyDir: { medium: Memory, sizeLimit: 16Gi } }
