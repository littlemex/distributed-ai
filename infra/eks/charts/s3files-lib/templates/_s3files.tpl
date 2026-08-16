{{- /*
s3files.pv-pvc — a static PV + PVC binding one AWS S3 Files file system to a namespace via the
EFS CSI driver, factored out of analysis-mcp and remote-mcp so the volumeHandle gotcha is encoded
exactly once (the two copies had already diverged — analysis-mcp had the strong two-`fail`
validation, remote-mcp a weaker single check; the third consumer would copy whichever it saw).

volumeHandle MUST be "s3files:<FileSystemId>::<AccessPointId>" — a bare EFS fs-id makes the CSI
driver take the EFS path and the mount fails (mount.nfs4: access denied); an access point is
mandatory. accessModes is ReadWriteMany (the driver does not implement ReadOnlyMany); the
read-only guarantee is enforced by the consuming pod's volume readOnly flag, not here.

Called with a dict of:
  name          (required) metadata.name shared by the PV and PVC (PVC.volumeName binds them)
  namespace     (required) the PVC's namespace
  volumeHandle  (required) "s3files:<fs>::<ap>"
  zone          (optional) the mount target's AZ (topology.kubernetes.io/zone). STRONGLY
                recommended: the single mount target is reachable only from its AZ (NFS DNS
                resolves per-AZ), so without this a pod scheduled in another AZ hangs forever in
                ContainerCreating. Set it to the s3files_mount_target_az Terraform output.
  capacity      (optional) nominal storage request, default 5Gi (S3 Files is not capacity-bound)
Canonical caller:
  {{- include "s3files.pv-pvc" (dict "name" "analysis-mcp-traces" "namespace" "mcp"
        "volumeHandle" .Values.s3files.volumeHandle "zone" .Values.s3files.zone) }}
*/ -}}
{{- define "s3files.pv-pvc" -}}
{{- $name := .name | required "s3files.pv-pvc: name is required" -}}
{{- $ns := .namespace | required "s3files.pv-pvc: namespace is required" -}}
{{- $vh := .volumeHandle -}}
{{- if not $vh }}{{ fail "s3files.pv-pvc: volumeHandle is required: \"s3files:<FileSystemId>::<AccessPointId>\" (create an S3 Files access point; a bare fs-id will not mount)" }}{{- end }}
{{- if not (hasPrefix "s3files:" $vh) }}{{ fail (printf "s3files.pv-pvc: volumeHandle must start with \"s3files:\" (got %q) — a bare EFS fs-id takes the EFS path and fails to mount an S3 Files file system" $vh) }}{{- end }}
{{- $cap := .capacity | default "5Gi" -}}
apiVersion: v1
kind: PersistentVolume
metadata:
  name: {{ $name | quote }}
spec:
  capacity: { storage: {{ $cap }} }   # nominal; S3 Files is not capacity-bound
  volumeMode: Filesystem
  accessModes: ["ReadWriteMany"]
  # Mount the NFS filesystem READ-ONLY at the node (-o ro), not merely via the pod's volume
  # readOnly flag: this makes writes/deletes fail at the mount layer regardless of what a consuming
  # pod requests, so the "only the janitor deletes" invariant cannot be bypassed by a pod that
  # references this cluster-scoped PV with readOnly:false (defense in depth for the IAM enforcement;
  # B1). Producers write to the trace bucket through the S3 API, never through this mount.
  mountOptions: ["ro"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  {{- if .zone }}
  # Pin consumers to the mount target's AZ — the NFS endpoint resolves only from that AZ, so a
  # cross-AZ pod would hang in ContainerCreating. The scheduler honours a PV's nodeAffinity.
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - { key: topology.kubernetes.io/zone, operator: In, values: [{{ .zone | quote }}] }
  {{- end }}
  csi:
    driver: efs.csi.aws.com
    volumeHandle: {{ $vh | quote }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ $name | quote }}
  namespace: {{ $ns | quote }}
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: ""
  resources: { requests: { storage: {{ $cap }} } }
  volumeName: {{ $name | quote }}
{{- end -}}
