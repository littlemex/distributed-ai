# cpu-gpu-torchrun-train.yaml.tpl
#
# Zero-operator smoke test: single-Pod, single-node HF Trainer fine-tune of
# HuggingFaceTB/SmolLM2-135M on a databricks-dolly-15k slice, launched with plain
# `torchrun --nproc_per_node`. No MPIJob, no mpi-operator — just a batch/v1 Job. This is the
# "clone and run in five minutes" check that the module's launch story works at all; the
# multi-NODE story (2+ machines) is gpu-distributed-mpijob-train.yaml.tpl, which reuses the
# same train_smollm.py and the same __MPIJOB_IMAGE__ image (see that file for why a custom
# image is needed there — Open MPI + sshd baked in). This sample reuses the same image purely
# for consistency (one image, two launch stories); a stock pytorch/pytorch image would work
# here too since torchrun needs nothing beyond the base image + pip installs.
#
# torchrun sets RANK/WORLD_SIZE/LOCAL_RANK/MASTER_ADDR/MASTER_PORT itself (env:// rendezvous),
# so train_smollm.py's OMPI_* shim is inert here — it only fires when OMPI_COMM_WORLD_RANK is
# present, which mpirun sets and torchrun does not. The image's USER mpiuser (uid 1000) is
# harmless for this single-Pod Job — no SSH is involved — but it does mean the EFS mount needs
# a permission fix, handled below by a root initContainer (the shared EFS access point's
# access point is owned by uid/gid 0; see efs.tf).
#
# Works on either backend:
#   - CPU (gloo): __NODE_ROLE__=cpu, __NPROC__=2, no GPU resources — needs cpu_nodepool_enabled=true.
#   - GPU (nccl): __NODE_ROLE__=<accelerator pool name, e.g. gpu-g5>, __NPROC__=<GPUs to use on
#     one node, e.g. 1>, GPU resources requested.
#
# Prerequisites:
#   - efs_enabled = true (creates the static PV `efs-neuron-workspace`, mounted here for the
#     HF cache and output checkpoint so a retried/rescheduled Pod does not re-download).
#   - For the CPU backend: cpu_nodepool_enabled = true.
#   - For the GPU backend: an accelerator pool with device_plugin="nvidia".
#   - The __MPIJOB_IMAGE__ image built from manifests/mpijob-image/ and pushed to your own ECR
#     (see that directory's README for the build/push commands).
#
# Usage (CPU):
#   NAMESPACE=<your-namespace>
#   IMAGE=<account>.dkr.ecr.<region>.amazonaws.com/mpijob-hf-sample:v1
#   sed -e "s/__NAMESPACE__/${NAMESPACE}/g" -e "s#__MPIJOB_IMAGE__#${IMAGE}#g" \
#       -e "s/__NODE_ROLE__/cpu/g" -e "s/__NPROC__/2/g" -e "s/__BACKEND__/gloo/g" \
#       -e '/__GPU_RESOURCES_IF_NEEDED__/d' -e '/__GPU_TOLERATIONS_IF_NEEDED__/d' \
#       cpu-gpu-torchrun-train.yaml.tpl | kubectl apply -f -
#
# Usage (GPU, e.g. one g5 node, 1 GPU):
#   NAMESPACE=<your-namespace>
#   IMAGE=<account>.dkr.ecr.<region>.amazonaws.com/mpijob-hf-sample:v1
#   sed -e "s/__NAMESPACE__/${NAMESPACE}/g" -e "s#__MPIJOB_IMAGE__#${IMAGE}#g" \
#       -e "s/__NODE_ROLE__/gpu-g5/g" -e "s/__NPROC__/1/g" -e "s/__BACKEND__/nccl/g" \
#       -e 's/__GPU_RESOURCES_IF_NEEDED__/nvidia.com\/gpu: "1"/' \
#       -e 's/__GPU_TOLERATIONS_IF_NEEDED__/{ key: nvidia.com\/gpu, operator: Exists, effect: NoSchedule }/' \
#       cpu-gpu-torchrun-train.yaml.tpl | kubectl apply -f -
#
# Verify:
#   kubectl -n $NAMESPACE logs -f job/smollm-torchrun
#   kubectl -n $NAMESPACE wait --for=condition=complete job/smollm-torchrun --timeout=20m
#   # Expect NUM_EPOCHS worth of "[rank N/__NPROC__]" loss logs from every rank, then
#   # "saving final model" from rank 0 only.
# ─────────────────────────────────────────────────────────────────────────────
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-shared-claim
  namespace: __NAMESPACE__
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: ""
  volumeName: efs-neuron-workspace
  resources:
    requests:
      storage: 1000Gi
---
apiVersion: batch/v1
kind: Job
metadata:
  name: smollm-torchrun
  namespace: __NAMESPACE__
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: { app: smollm-torchrun }
      # The CPU NodePool's consolidationPolicy is WhenEmptyOrUnderutilized with a 30s
      # consolidateAfter (karpenter-resources.tf) — Karpenter can decide a node running this
      # single Pod is consolidatable and evict it mid-training (reproduced on this cluster
      # with the MPIJob sibling sample's Workers: "Evicted pod: Underutilized"). Harmless on
      # the GPU pools, which use consolidationPolicy WhenEmpty, but required on cpu.
      annotations:
        karpenter.sh/do-not-disrupt: "true"
    spec:
      restartPolicy: Never
      nodeSelector:
        node-role: __NODE_ROLE__
      tolerations:
        - { key: capacity-reservation, operator: Exists, effect: NoSchedule }
        - __GPU_TOLERATIONS_IF_NEEDED__
      # The EFS access point (efs.tf) is owned by uid/gid 0; the image's mpiuser is uid 1000.
      # A root initContainer creates and hands over a per-sample subdirectory once, so the
      # main container never needs elevated privileges.
      initContainers:
        - name: fix-perms
          image: __MPIJOB_IMAGE__
          securityContext: { runAsUser: 0 }
          command:
            - /bin/bash
            - -c
            - |
              mkdir -p /shared/hf-cache /shared/output/torchrun-__BACKEND__
              # Scoped to this sample's own subdirectories, not the whole shared volume:
              # /shared/output accumulates other samples' checkpoints over time, and a
              # recursive chown across all of it over EFS gets slower on every rerun.
              chown -R 1000:1000 /shared/hf-cache /shared/output/torchrun-__BACKEND__
          volumeMounts:
            - { name: shared, mountPath: /shared }
      containers:
        - name: train
          image: __MPIJOB_IMAGE__
          command:
            - torchrun
            - --standalone
            - --nproc_per_node=__NPROC__
            - /home/mpiuser/train_smollm.py
          env:
            - { name: HF_HOME, value: /shared/hf-cache }
            - { name: OUTPUT_DIR, value: /shared/output/torchrun-__BACKEND__ }
          resources:
            limits:
              __GPU_RESOURCES_IF_NEEDED__
              memory: 16Gi
            requests:
              cpu: "4"
              memory: 16Gi
          volumeMounts:
            - { name: shared, mountPath: /shared }
            - { name: shm, mountPath: /dev/shm }
      volumes:
        - { name: shared, persistentVolumeClaim: { claimName: efs-shared-claim } }
        - { name: shm, emptyDir: { medium: Memory, sizeLimit: 4Gi } }
