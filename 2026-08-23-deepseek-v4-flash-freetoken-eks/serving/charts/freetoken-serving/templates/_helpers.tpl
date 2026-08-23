{{- define "freetoken-serving.name" -}}
ft-{{ .Values.model | lower | replace "/" "-" | replace "." "-" | replace "_" "-" | trunc 50 | trimSuffix "-" }}
{{- end -}}

{{- define "freetoken-serving.served" -}}
{{- if .Values.servedModelName -}}{{ .Values.servedModelName }}{{- else -}}{{ .Values.model }}{{- end -}}
{{- end -}}

{{- /*
Where FreeToken should read the checkpoint from. With source=hf, `model` is an HF repo id and
FreeToken downloads it. With source=s3files, the checkpoint is already on the shared mount, so the
repo id would trigger a pointless re-download -- resolve to the mounted path instead.
*/ -}}
{{- define "freetoken-serving.modelPath" -}}
{{- if eq .Values.checkpoint.source "s3files" -}}
{{- $sub := .Values.checkpoint.s3files.subPath | default "" -}}
{{- if $sub -}}/models/{{ $sub | trimPrefix "/" | trimSuffix "/" }}{{- else -}}/models{{- end -}}
{{- else -}}
{{- .Values.model -}}
{{- end -}}
{{- end -}}

{{- define "freetoken-serving.labels" -}}
app.kubernetes.io/name: freetoken-serving
app.kubernetes.io/instance: {{ include "freetoken-serving.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
