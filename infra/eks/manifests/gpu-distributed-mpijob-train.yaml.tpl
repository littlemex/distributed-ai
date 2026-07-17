# gpu-distributed-mpijob-train.yaml.tpl
#
# Multi-node HF Trainer fine-tune of HuggingFaceTB/SmolLM2-135M via kubeflow.org/v2beta1
# MPIJob (Launcher + 2 Workers). This is the first MPIJob workload in this module —
# mpi-operator (gpu-addons.tf) is installed unconditionally but until now had no sample
# exercising it. Counterpart to cpu-gpu-torchrun-train.yaml.tpl (single-node, zero-operator);
# this is the "now scale it to two nodes" step.
#
# Why MPIJob instead of RayCluster/plain torchrun for the multi-node case: mpi-operator is
# already vendored in this module (manifests/mpi-operator-v0.6.0.yaml) and needs no new
# controller. mpirun launches one process per worker slot over SSH and sets
# OMPI_COMM_WORLD_RANK/SIZE/LOCAL_RANK on each — NOT the RANK/WORLD_SIZE/LOCAL_RANK/
# MASTER_ADDR/MASTER_PORT that torch.distributed's env:// rendezvous requires. train_smollm.py
# (baked into __MPIJOB_IMAGE__, see manifests/mpijob-image/) carries the shim that translates
# OMPI_* into those, with MASTER_ADDR hardcoded to "<job name>-worker-0" (the Service DNS name
# mpi-operator derives for worker replica 0) — verified end-to-end with a 2-process local
# rehearsal before this manifest was written.
#
# The image: pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime ships neither Open MPI nor sshd
# (verified with `finch run --rm <image> which mpirun sshd` — nothing). manifests/mpijob-image/
# layers Open MPI + openssh-server + the mpi-operator SSH config (vendored from
# github.com/kubeflow/mpi-operator's own build/base/Dockerfile — the same base every upstream
# v2beta1 example, e.g. examples/v2beta1/pi, builds on) + transformers/datasets/accelerate on
# top of it, exactly mirroring upstream's runAsUser: 1000 / mpiuser pattern. The Worker's
# command/args below are explicit (not left to mpi-operator's auto-injection) — see the
# comment on the Worker container for why. Build once, push to your own ECR, and reference the
# digest here — see that directory's README for the exact commands (also covers the Apple
# Silicon --platform linux/amd64 gotcha if you build locally with finch).
#
# Gotcha worth flagging: a non-interactive SSH command does NOT inherit the image's Docker
# ENV PATH (verified: `ssh -p 2222 host 'echo $PATH'` shows only /usr/bin:/bin, missing
# /opt/conda/bin where this image's python3 lives) — so the Launcher's mpirun invokes Python
# by the absolute path /opt/conda/bin/python3, not a bare `python3` that relies on PATH.
#
# Works on either backend:
#   - CPU (gloo): __NODE_ROLE__=cpu, no GPU resources — needs cpu_nodepool_enabled=true.
#   - GPU (nccl): __NODE_ROLE__=<accelerator pool name, e.g. gpu-g5 or gpu-g6e>, GPU resources
#     requested, one worker pod per node (podAntiAffinity) so this genuinely spans 2 machines.
#
# Prerequisites:
#   - mpi-operator is always installed by this module (gpu-addons.tf) — no extra apply needed.
#   - efs_enabled = true (HF cache + output checkpoint on the static PV `efs-neuron-workspace`,
#     shared by launcher and both workers).
#   - For the CPU backend: cpu_nodepool_enabled = true, and at least 2 schedulable CPU nodes
#     (or let Karpenter provision 2 — podAntiAffinity forces one worker per node).
#   - For the GPU backend: an accelerator pool with device_plugin="nvidia" and enough quota
#     for 2 nodes.
#
# Usage (CPU, 2 workers):
#   NAMESPACE=<your-namespace>
#   IMAGE=<account>.dkr.ecr.<region>.amazonaws.com/mpijob-hf-sample:v1
#   sed -e "s/__NAMESPACE__/${NAMESPACE}/g" -e "s#__MPIJOB_IMAGE__#${IMAGE}#g" \
#       -e "s/__NODE_ROLE__/cpu/g" -e "s/__BACKEND__/gloo/g" \
#       -e '/__GPU_RESOURCES_IF_NEEDED__/d' -e '/__GPU_TOLERATIONS_IF_NEEDED__/d' \
#       gpu-distributed-mpijob-train.yaml.tpl | kubectl apply -f -
#
# Usage (GPU, e.g. 2 g5 nodes, 1 GPU per worker):
#   NAMESPACE=<your-namespace>
#   IMAGE=<account>.dkr.ecr.<region>.amazonaws.com/mpijob-hf-sample:v1
#   sed -e "s/__NAMESPACE__/${NAMESPACE}/g" -e "s#__MPIJOB_IMAGE__#${IMAGE}#g" \
#       -e "s/__NODE_ROLE__/gpu-g5/g" -e "s/__BACKEND__/nccl/g" \
#       -e 's/__GPU_RESOURCES_IF_NEEDED__/nvidia.com\/gpu: "1"/' \
#       -e 's/__GPU_TOLERATIONS_IF_NEEDED__/{ key: nvidia.com\/gpu, operator: Exists, effect: NoSchedule }/' \
#       gpu-distributed-mpijob-train.yaml.tpl | kubectl apply -f -
#
# Verify:
#   kubectl -n $NAMESPACE get mpijob smollm-mpijob -w
#   kubectl -n $NAMESPACE logs -f job/smollm-mpijob-launcher
#   # Expect "[rank 0/2]" through "[rank 1/2]" loss logs interleaved (2 workers, 1 slot each),
#   # then "saving final model" from rank 0 only, then the launcher Job completes.
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
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: smollm-mpijob
  namespace: __NAMESPACE__
spec:
  slotsPerWorker: 1
  # Default AtStartup creates the Launcher immediately; its first mpirun then races the
  # Workers' initContainer (the EFS chown -R below) + sshd startup and fails DNS resolution
  # on the not-yet-Ready Worker Service records, burning through restartPolicy: OnFailure's
  # backoff budget before the Workers are ever ready — reproduced on this cluster: the
  # Launcher hit BackoffLimitExceeded while both Workers were still in Init:0/1. Waiting for
  # Ready fixes it at the source instead of papering over it with a longer backoff budget.
  launcherCreationPolicy: WaitForWorkersReady
  runPolicy:
    cleanPodPolicy: Running
  sshAuthMountPath: /home/mpiuser/.ssh
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      restartPolicy: OnFailure
      template:
        metadata:
          # The CPU NodePool's consolidationPolicy is WhenEmptyOrUnderutilized with a 30s
          # consolidateAfter (karpenter-resources.tf) — tuned for idle-teardown speed on
          # single-Pod workloads, but it evicted a Worker mid-run in an earlier rehearsal of
          # this exact manifest ("Evicted pod: Underutilized" — Karpenter saw the 4-vCPU
          # request on an 8-vCPU node as consolidatable and moved it, tearing down sshd out
          # from under a live mpirun). Harmless on the GPU pools, which use consolidationPolicy
          # WhenEmpty, but required here.
          annotations:
            karpenter.sh/do-not-disrupt: "true"
        spec:
          nodeSelector:
            node-role: __NODE_ROLE__
          tolerations:
            - { key: capacity-reservation, operator: Exists, effect: NoSchedule }
            - __GPU_TOLERATIONS_IF_NEEDED__
          containers:
            - name: mpi-launcher
              image: __MPIJOB_IMAGE__
              securityContext: { runAsUser: 1000 }
              command:
                - mpirun
              args:
                - -np
                - "2"
                - -x
                - MPIJOB_MASTER_ADDR=smollm-mpijob-worker-0
                - -x
                - HF_HOME=/shared/hf-cache
                - -x
                - OUTPUT_DIR=/shared/output/mpijob-__BACKEND__
                # Non-interactive SSH does not inherit the image's Docker ENV PATH (verified —
                # see the header comment), so this is an absolute path, not a bare `python3`.
                - /opt/conda/bin/python3
                - /home/mpiuser/train_smollm.py
              resources:
                limits: { memory: 2Gi }
                requests: { cpu: "1", memory: 2Gi }
    Worker:
      replicas: 2
      restartPolicy: Never
      template:
        metadata:
          # See the identical annotation on the Launcher above — same reason, same fix.
          annotations:
            karpenter.sh/do-not-disrupt: "true"
        spec:
          nodeSelector:
            node-role: __NODE_ROLE__
          tolerations:
            - { key: capacity-reservation, operator: Exists, effect: NoSchedule }
            - __GPU_TOLERATIONS_IF_NEEDED__
          # One worker per physical node — otherwise 2 workers could land on the same node
          # and the run would not actually exercise cross-node communication.
          affinity:
            podAntiAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                - labelSelector:
                    matchLabels: { training.kubeflow.org/job-name: smollm-mpijob }
                  topologyKey: kubernetes.io/hostname
          containers:
            - name: mpi-worker
              image: __MPIJOB_IMAGE__
              securityContext: { runAsUser: 1000 }
              # Explicit, not left to mpi-operator's auto-injection: when command/args are both
              # unset, mpi-operator v0.6.0 injects only `/usr/sbin/sshd -De` — NOT `-f
              # /home/mpiuser/.sshd_config` (confirmed by reading pkg/controller/
              # mpi_job_controller.go's newWorker(), and by reproducing it on this cluster: the
              # Worker Pod's rendered command really is just ["/usr/sbin/sshd", "-De"]). Without
              # -f, sshd reads the stock /etc/ssh/sshd_config, which points at
              # /etc/ssh/ssh_host_*_key — never generated in this image (no ssh-keygen -A) —
              # and exits with "no hostkeys available". Passing -f explicitly, exactly like
              # upstream's own examples/v2beta1/pi, is what makes it find the image's
              # HostKey /home/mpiuser/.ssh/id_rsa (which setupSSHOnPod's unconditional ssh-auth
              # volume mount, at sshAuthMountPath, actually does provide).
              command: [/usr/sbin/sshd]
              args: [-De, -f, /home/mpiuser/.sshd_config]
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
          # The EFS access point (efs.tf) is owned by uid/gid 0; mpiuser is uid 1000. Both
          # Worker replicas run this (mkdir -p / chown -R are idempotent, so the harmless
          # overlap is cheaper than coordinating a single run).
          initContainers:
            - name: fix-perms
              image: __MPIJOB_IMAGE__
              securityContext: { runAsUser: 0 }
              command:
                - /bin/bash
                - -c
                - |
                  mkdir -p /shared/hf-cache /shared/output/mpijob-__BACKEND__
                  # Scoped to this sample's own subdirectories, not the whole shared volume:
                  # /shared/output accumulates other samples' checkpoints over time, and a
                  # recursive chown across all of it over EFS is slow enough to starve
                  # launcherCreationPolicy: WaitForWorkersReady's patience.
                  chown -R 1000:1000 /shared/hf-cache /shared/output/mpijob-__BACKEND__
              volumeMounts:
                - { name: shared, mountPath: /shared }
          volumes:
            - { name: shared, persistentVolumeClaim: { claimName: efs-shared-claim } }
            - { name: shm, emptyDir: { medium: Memory, sizeLimit: 4Gi } }
