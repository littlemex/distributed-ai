{{/*
Shared helpers for the ocr-serving chart. Mirrors the base module's charts/experiments and
the comfyui project idioms.
*/}}

{{/*
Target namespace. Prefer an explicit --set namespace=, else fall back to the Helm
-n/--namespace flag (.Release.Namespace), so both forms work and `-n $NS` is never
silently ignored. quote so a namespace like "true" is not YAML-coerced to a bool.
*/}}
{{- define "ocr.namespace" -}}
{{ .Values.namespace | default .Release.Namespace | quote }}
{{- end -}}

{{/*
NVIDIA GPU pool tolerations for a serving pod. The GPU serving pool is not bench-tainted,
so only the three standard taints are needed (device plugin + EFA + Capacity Block).
Caller supplies indentation:
  tolerations:
    {{- include "ocr.gpuTolerations" . | nindent 8 }}
*/}}
{{- define "ocr.gpuTolerations" -}}
- { key: nvidia.com/gpu,        operator: Exists, effect: NoSchedule }
- { key: vpc.amazonaws.com/efa, operator: Exists, effect: NoSchedule }
- { key: capacity-reservation,  operator: Exists, effect: NoSchedule }
{{- end -}}

{{/*
ocr.imageBuild — render an in-cluster BuildKit build Job for ONE engine, as a thin caller of
the shared image-builder.job define. Called with a dict:
    { root: $, key: "paddleocr", build: <the engine's .build values> }
The top-level imageBuild block carries the shared context (repository, gitRepo/Ref, namespace,
SA, contextSubPath); the engine's .build block carries its identity + sizing (tag, filename,
optional per-engine repository, cpu, ephemeralStorage, dedicatedPool). A per-engine repository
falls back to imageBuild.repository so a single borrowed ECR repo (distinct tags) or dedicated
repos both work.
*/}}
{{- define "ocr.imageBuild" -}}
{{- $root := .root -}}
{{- $b := .build | default dict -}}
{{- $ib := $root.Values.imageBuild -}}
{{- $args := deepCopy $ib -}}
{{- $_ := set $args "jobName" (printf "build-ocr-%s" .key) -}}
{{- $_ := set $args "tag" (required (printf "%s.build.tag is required" .key) $b.tag) -}}
{{- $_ := set $args "filename" (required (printf "%s.build.filename is required (Dockerfile.<engine>)" .key) $b.filename) -}}
{{- $_ := set $args "repository" ($b.repository | default $ib.repository) -}}
{{- $_ := set $args "cpu" ($b.cpu | default "2") -}}
{{- $_ := set $args "ephemeralStorage" ($b.ephemeralStorage | default "30Gi") -}}
{{- if $b.dedicatedPool }}{{- $_ := set $args "dedicatedPool" $b.dedicatedPool -}}{{- end }}
{{- include "image-builder.job" $args -}}
{{- end -}}

{{/*
ocr.workload — render a serving Deployment + ClusterIP Service for ONE engine. Called with:
    { root: $, key: "paddleocr", cfg: <the engine's serving values>, gpu: true }
`cfg` fields: image (required), nodeRole (required), gpuCount, cpu, memory, shmSize, port,
startupProbe/readinessProbe/livenessProbe. GPU pods get the accelerator tolerations + a
gpu limit; CPU pods (gpu=false) get neither and land on the cpu pool. Health uses the
harness endpoints: /healthz (liveness, process up) and /readyz (readiness, model loaded).
*/}}
{{- define "ocr.workload" -}}
{{- $root := .root -}}
{{- $key := .key -}}
{{- $c := .cfg -}}
{{- $gpu := .gpu -}}
{{- $ns := include "ocr.namespace" $root -}}
{{- $port := $c.port | default 8000 -}}
{{- if not $c.image }}{{ fail (printf "%s.image is required — the ECR image built by imageBuild (repository:tag)." $key) }}{{- end }}
{{- if not $c.nodeRole }}{{ fail (printf "%s.nodeRole is required — the node-role label of the pool this lands on (e.g. gpu-ddp for GPU, cpu for Tesseract). Without it the pod gets an empty selector and never schedules." $key) }}{{- end }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $key }}
  namespace: {{ $ns }}
  labels:
    app: {{ $key }}
    app.kubernetes.io/part-of: ocr-serving
spec:
  replicas: 1
  # Single GPU per engine: a rolling update would leave the new pod Pending on the GPU the
  # old pod still holds. Recreate also keeps CPU engines simple (no double-schedule).
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: {{ $key }}
  template:
    metadata:
      labels:
        app: {{ $key }}
        app.kubernetes.io/part-of: ocr-serving
      {{- if $gpu }}
      annotations:
        # Do not let Karpenter consolidation evict a GPU serving pod mid-request.
        karpenter.sh/do-not-disrupt: "true"
      {{- end }}
    spec:
      nodeSelector:
        node-role: {{ $c.nodeRole }}
      {{- if $gpu }}
      tolerations:
        {{- include "ocr.gpuTolerations" $root | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ $key }}
          image: {{ $c.image }}
          # A mutable tag + IfNotPresent would silently run a stale cached image after a
          # rebuild of the same tag. Bump the tag per rebuild (recommended) and pull Always.
          imagePullPolicy: {{ $c.imagePullPolicy | default "Always" }}
          ports:
            - { name: http, containerPort: {{ $port }} }
          resources:
            requests:
              cpu: {{ $c.cpu | default "2" | quote }}
              memory: {{ $c.memory | default "4Gi" }}
            limits:
              memory: {{ $c.memory | default "4Gi" }}
              {{- if $gpu }}
              nvidia.com/gpu: {{ $c.gpuCount | default 1 | quote }}
              {{- end }}
          # Liveness = process up (does NOT require the model, so a slow load never kills the
          # pod). Readiness = /readyz, which flips true only once the engine's model is loaded,
          # gating the Service until the pod can actually serve.
          startupProbe:
            httpGet: { path: /healthz, port: {{ $port }} }
            initialDelaySeconds: {{ (default dict $c.startupProbe).initialDelaySeconds | default 10 }}
            periodSeconds: {{ (default dict $c.startupProbe).periodSeconds | default 10 }}
            failureThreshold: {{ (default dict $c.startupProbe).failureThreshold | default 60 }}
          readinessProbe:
            httpGet: { path: /readyz, port: {{ $port }} }
            periodSeconds: {{ (default dict $c.readinessProbe).periodSeconds | default 10 }}
            failureThreshold: {{ (default dict $c.readinessProbe).failureThreshold | default 6 }}
          livenessProbe:
            httpGet: { path: /healthz, port: {{ $port }} }
            periodSeconds: {{ (default dict $c.livenessProbe).periodSeconds | default 30 }}
            failureThreshold: {{ (default dict $c.livenessProbe).failureThreshold | default 6 }}
          {{- if $gpu }}
          volumeMounts:
            - { name: shm, mountPath: /dev/shm }
          {{- end }}
      {{- if $gpu }}
      volumes:
        - name: shm
          emptyDir: { medium: Memory, sizeLimit: {{ $c.shmSize | default "1Gi" }} }
      {{- end }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $key }}
  namespace: {{ $ns }}
  labels:
    app: {{ $key }}
    app.kubernetes.io/part-of: ocr-serving
spec:
  # ClusterIP only — no auth on the engines, reached via `kubectl port-forward`.
  type: ClusterIP
  selector:
    app: {{ $key }}
  ports:
    - { name: http, port: {{ $port }}, targetPort: {{ $port }} }
{{- end -}}
