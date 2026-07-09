# nccl-test-probe-pod.yaml.tpl
#
# Single-node EFA sanity probe — confirms that:
#   1. The pod lands on a B300 node with an EFA ENI attached.
#   2. /dev/gdrdrv is present (gdrcopy-loader DaemonSet must be Running).
#   3. fi_info -p efa returns provider entries (EFA functional).
#
# Usage:
#   NAMESPACE=<your-namespace>
#   sed "s/__NAMESPACE__/${NAMESPACE}/g" nccl-test-probe-pod.yaml.tpl \
#     | kubectl apply -f -
#
# Verify inside the pod:
#   kubectl -n $NAMESPACE exec nccl-probe -- fi_info -p efa -t FI_EP_RDM
#   # Healthy B300: 32 entries (16 NIC x efa-direct/efa).
#
#   kubectl -n $NAMESPACE exec nccl-probe -- ls -l /dev/gdrdrv
#   # Confirms GPUDirect path is available.
#
# Ref: investigations/gpudirect-rdma-demo/manifests/00-probe.yaml
#      CLUSTER-GUIDE.md §1 (taints), §2 (EFA/GPUDirect), §8.1 (fi_info check)
# ─────────────────────────────────────────────────────────────────────────────
apiVersion: v1
kind: Pod
metadata:
  name: nccl-probe
  namespace: __NAMESPACE__
  labels:
    app: nccl-probe
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  restartPolicy: Never

  # Pin to a B300 node.  Swap the label value for a specific hostname if needed:
  #   kubernetes.io/hostname: ip-10-3-x-x.us-east-2.compute.internal
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-B300-SXM6-AC

  # All five B300 taints.  capacity-reservation value rotates per CB reservation,
  # so operator: Exists is mandatory (VERIFIED_FACTS.md, CLUSTER-GUIDE.md §1).
  tolerations:
    - { key: nvidia.com/gpu,                          operator: Exists, effect: NoSchedule }
    - { key: vpc.amazonaws.com/efa,                   operator: Exists, effect: NoSchedule }
    - { key: workload,                                 operator: Equal,  value: bench, effect: NoSchedule }
    - { key: capacity-reservation,                    operator: Exists, effect: NoSchedule }
    - { key: sagemaker.amazonaws.com/node-health-status, operator: Equal, value: Schedulable, effect: NoSchedule }

  containers:
    - name: probe
      # Public ECR image maintained by AWS HPC; includes EFA tools + nccl-tests binaries.
      # Ref: investigations/gpudirect-rdma-demo/ — confirmed working on B300 nodes.
      image: public.ecr.aws/hpc-cloud/nccl-tests:latest
      command: ["sleep", "3600"]
      securityContext:
        privileged: true   # Required for EFA and /dev/gdrdrv access.

      # NCCL_SOCKET_IFNAME uses the exclusion prefix "^" to avoid TCP fallback.
      # Using a positive match (e.g. "eth0") hides EFA and causes ~28x slowdown.
      # Ref: CLUSTER-GUIDE.md §2, §8.1; VERIFIED_FACTS.md NCCL_SOCKET_IFNAME note.
      env:
        - { name: FI_PROVIDER,            value: "efa" }
        - { name: FI_EFA_USE_DEVICE_RDMA, value: "1" }
        - { name: FI_EFA_FORK_SAFE,       value: "1" }
        - { name: NCCL_SOCKET_IFNAME,     value: "^lo,docker,veth" }
        - { name: NCCL_DEBUG,             value: "WARN" }

      resources:
        limits:
          nvidia.com/gpu:        "1"    # Minimal GPU claim; enough to open CUDA context.
          vpc.amazonaws.com/efa: "1"    # One EFA ENI; sufficient for fi_info probe.
          hugepages-2Mi:         2Gi    # Required when requesting EFA (RDMA reg).
          memory:                16Gi
        requests:
          cpu:           "4"
          memory:        16Gi
          hugepages-2Mi: 2Gi

      volumeMounts:
        # /dev/gdrdrv is created by the gdrcopy-loader DaemonSet (or gpu-operator).
        # Absent → GPUDirect small-copy path is unavailable; NCCL falls back to sysmem copy.
        - { name: gdrdrv, mountPath: /dev/gdrdrv }
        - { name: shm,    mountPath: /dev/shm }

  volumes:
    - { name: gdrdrv, hostPath: { path: /dev/gdrdrv, type: CharDevice } }
    - { name: shm,    emptyDir: { medium: Memory, sizeLimit: 8Gi } }
