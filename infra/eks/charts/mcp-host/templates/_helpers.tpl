{{/*
Fixed namespace for all hosted MCPs. Hardcoded (not a value): "mcp" is the only namespace carrying
the Pod Security label and the Pod-Identity associations (infra/eks/iam-mcp.tf). Making it a knob
that must equal one value only moves a silent failure (pod rejected for no PSS label, or Pod
Identity never binding) from render time to runtime.
*/}}
{{- define "mcphost.namespace" -}}mcp{{- end -}}
