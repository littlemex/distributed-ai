{{/*
Shared helpers for the comfyui chart. Mirrors the base module's charts/experiments idioms.
*/}}

{{/*
Target namespace. Prefer an explicit --set namespace=, else fall back to the Helm
-n/--namespace flag (.Release.Namespace), so both forms work and `-n $NS` is never
silently ignored. quote so a namespace like "true" is not YAML-coerced to a bool.
*/}}
{{- define "comfyui.namespace" -}}
{{ .Values.namespace | default .Release.Namespace | quote }}
{{- end -}}

{{/*
Shared-storage PVC name. REQUIRED — sharedStorage.existingClaimName. The PVC is created
ONCE by hand (base module manifests/shared-pvc.yaml) so its lifecycle matches the OpenZFS
static PV's, not a workload's re-apply cycle. fail loudly if unset rather than render a
pod that mounts nothing.
*/}}
{{- define "comfyui.sharedClaimName" -}}
{{- if not .Values.sharedStorage.existingClaimName -}}
{{ fail "sharedStorage.existingClaimName is required — apply the base module's manifests/shared-pvc.yaml once (bound to the openzfs-shared PV) and pass its name here. See docs/GETTING_STARTED.md." }}
{{- end -}}
{{- .Values.sharedStorage.existingClaimName -}}
{{- end -}}

{{/*
NVIDIA GPU pool tolerations for the ComfyUI serving pod. The g6e serving pool is not
bench-tainted, so only the three standard taints are needed (device plugin + EFA + CB).
Caller supplies indentation:
  tolerations:
    {{- include "comfyui.gpuTolerations" . | nindent 8 }}
*/}}
{{- define "comfyui.gpuTolerations" -}}
- { key: nvidia.com/gpu,        operator: Exists, effect: NoSchedule }
- { key: vpc.amazonaws.com/efa, operator: Exists, effect: NoSchedule }
- { key: capacity-reservation,  operator: Exists, effect: NoSchedule }
{{- end -}}
