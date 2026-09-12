{{- define "vllm-serving.name" -}}
vllm-{{ .Values.model | lower | replace "/" "-" | replace "." "-" | replace "_" "-" | trunc 50 | trimSuffix "-" }}
{{- end -}}

{{- define "vllm-serving.served" -}}
{{- if .Values.servedModelName -}}{{ .Values.servedModelName }}{{- else -}}{{ .Values.model }}{{- end -}}
{{- end -}}

{{- define "vllm-serving.labels" -}}
app.kubernetes.io/name: vllm-serving
app.kubernetes.io/instance: {{ include "vllm-serving.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
