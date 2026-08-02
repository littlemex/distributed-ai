{{/*
Shared helpers for the experiments chart.
*/}}

{{/*
Target namespace. Prefer an explicit --set namespace=, else fall back to the Helm
-n/--namespace flag (.Release.Namespace). This makes `helm template -n $NS ...` and
`--set namespace=$NS` both work — without this, `-n $NS` would be silently ignored and
every object would render into `default`, so a later `kubectl -n $NS ...` finds nothing.
quote so a namespace like "true"/"off" is not YAML-coerced to a bool.
*/}}
{{- define "experiments.namespace" -}}
{{ .Values.namespace | default .Release.Namespace | quote }}
{{- end -}}

{{/*
Shared-storage static PV name for the training workloads' /shared mount. The three storage
backends each expose ONE static PV, created by the matching *.tf (all RWX):
  openzfs → "openzfs-shared"       (openzfs.tf; single-AZ NFS home/general-shared — DEFAULT)
  fsx     → "fsx-training"         (fsx.tf; single-AZ Lustre high-throughput scratch)
  efs     → "efs-neuron-workspace" (efs.tf; regional multi-AZ RWX — demoted opt-in)
The chosen filesystem must be enabled in Terraform (its var.<x>_enabled = true) so the PV
exists, or the PVC below stays Pending. fail on an unknown backend so a typo is caught at
render time rather than binding to nothing.
*/}}
{{- define "experiments.sharedVolumeName" -}}
{{- $b := .Values.sharedStorage.backend -}}
{{- if eq $b "openzfs" -}}openzfs-shared
{{- else if eq $b "fsx" -}}fsx-training
{{- else if eq $b "efs" -}}efs-neuron-workspace
{{- else -}}{{ fail (printf "sharedStorage.backend must be openzfs|fsx|efs, got %q" $b) }}
{{- end -}}
{{- end -}}

{{/*
Shared-storage PVC name. If sharedStorage.existingClaimName is set, use it directly
(no shared-pvc.yaml is rendered). Otherwise use the chart-created "shared-claim".
*/}}
{{- define "experiments.sharedClaimName" -}}
{{- .Values.sharedStorage.existingClaimName | default "shared-claim" -}}
{{- end -}}

{{/*
Resolve a Neuron DLC image. If the workload sets an explicit `image`, use it verbatim
(full override). Otherwise build "{dlc.registry}/{repoTag}" from the shared registry so the
region+account ID is defined once (see values.yaml `dlc`). Call as:
  {{ include "experiments.dlcImage" (dict "image" $v.image "repoTag" "pytorch-inference-neuronx:2.9.0-..." "root" $) }}
*/}}
{{- define "experiments.dlcImage" -}}
{{- if .image -}}{{ .image }}
{{- else -}}{{ .root.Values.dlc.registry }}/{{ .repoTag }}
{{- end -}}
{{- end -}}

{{/*
Neuron accelerator tolerations: the device-plugin taint, the EFA taint, and the
Capacity Block taint (value rotates per reservation, so Exists). Indented under a
`tolerations:` key by the caller; include with the correct indent, e.g.
  tolerations:
    {{- include "experiments.neuronTolerations" . | nindent 4 }}
*/}}
{{- define "experiments.neuronTolerations" -}}
- { key: aws.amazon.com/neuron, operator: Exists, effect: NoSchedule }
- { key: vpc.amazonaws.com/efa, operator: Exists, effect: NoSchedule }
- { key: capacity-reservation,  operator: Exists, effect: NoSchedule }
{{- end -}}

{{/*
NVIDIA/EFA bench-pool tolerations, shared by the nccl-probe and nccl-sshd workloads (the
GPU counterpart of neuronTolerations). Beyond the GPU + EFA + Capacity Block taints it also
tolerates the workload=bench pool taint and the SageMaker node-health taint. Caller supplies
indentation, e.g.
  tolerations:
    {{- include "experiments.gpuBenchTolerations" . | nindent 4 }}
Do NOT use this for gpu-serving-vllm / vllm-ray: those pools are not bench-tainted and only
need the 3-taint set.
*/}}
{{- define "experiments.gpuBenchTolerations" -}}
- { key: nvidia.com/gpu,                             operator: Exists, effect: NoSchedule }
- { key: vpc.amazonaws.com/efa,                      operator: Exists, effect: NoSchedule }
- { key: workload,                                   operator: Equal,  value: bench, effect: NoSchedule }
- { key: capacity-reservation,                       operator: Exists, effect: NoSchedule }
- { key: sagemaker.amazonaws.com/node-health-status, operator: Equal,  value: Schedulable, effect: NoSchedule }
{{- end -}}

{{/*
The bash command that runs sshd as PID-1 subordinate on port 2222. Neuron/CPU DLCs
do not all ship openssh-server, so install it idempotently. StrictHostKeyChecking off
avoids interactive mpirun/torchrun prompts. hostNetwork=true means port 22 is the
node's real sshd, so we use 2222.
*/}}
{{- define "experiments.sshdCommand" -}}
- bash
- -lc
- |
  mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh
  apt-get update -qq && apt-get install -y -qq openssh-server >/dev/null 2>&1 || true
  ssh-keygen -A
  sed -i 's/^#*Port .*/Port 2222/' /etc/ssh/sshd_config
  printf 'StrictHostKeyChecking no\nUserKnownHostsFile /dev/null\n' > /root/.ssh/config
  chmod 600 /root/.ssh/config
  /usr/sbin/sshd -D -p 2222
{{- end -}}

{{/*
Neuron runtime env block shared by the DDP pods. Caller supplies indentation:
  env:
    {{- include "experiments.neuronDdpEnv" . | nindent 8 }}
Expects the neuronDdp values map as the context (.).
*/}}
{{- define "experiments.neuronDdpEnv" -}}
{{- if .efaEnv }}
- { name: FI_PROVIDER,            value: "efa" }
- { name: FI_EFA_USE_DEVICE_RDMA, value: "1" }
- { name: FI_EFA_FORK_SAFE,       value: "1" }
{{- end }}
- { name: NEURON_LOGICAL_NC_CONFIG, value: {{ .lnc | quote }} }
{{- if .fiLogInfo }}
- { name: FI_LOG_LEVEL, value: "info" }
{{- end }}
{{- if .disableZerocopy }}
- { name: NEURON_RT_DBG_ZEROCOPY, value: "0" }
{{- end }}
{{- end -}}
