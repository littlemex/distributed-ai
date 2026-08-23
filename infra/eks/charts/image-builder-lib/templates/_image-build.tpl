{{- /*
image-builder.job — the generic in-cluster image builder, factored out of the
ddp-sample workshop Job so any image reuses the SAME build/push mechanism instead of copying
this template per image. Callers are thin templates that pass their image's identity (jobName,
and — for a git context — contextSubPath) alongside the imageBuild values; see
image-build-ddp-sample.yaml for the reference caller. The Terraform "mechanism" half (ECR repo,
IAM role, Pod Identity, image-builder namespace + SA) is unchanged (image-builder.tf); this
define is only the "execution" half.

Why BuildKit (not Kaniko): Kaniko is archived/unmaintained. BuildKit (moby/buildkit) is the
active, upstream-maintained builder; its rootless image runs the whole build in a user namespace
with NO privileged container and NO CAP_SYS_ADMIN, driven one-shot by buildctl-daemonless.sh.

Auth is settings-free at the IAM layer (Pod Identity), but BuildKit — unlike Kaniko — bundles no
ECR credential helper. So the ecr-login initContainer (AWS CLI) turns the Pod Identity
credentials into an ECR login token and writes a Docker config.json that BuildKit reads via
DOCKER_CONFIG. Verified live (2026-07-30): Pod Identity injects the container-credentials env
into initContainers too, and `aws ecr get-login-password` succeeds there.

Build context (contextSource):
  "git" (default) — clone gitRepo#gitRef, build root = contextSubPath. Kaniko-equivalent
    "#<ref>:<subdir>". This is the auditable, reproducible path — keep production images here.
  "configMap" — build from a ConfigMap with no clone and no git push, for ad-hoc/experiment
    images not committed to a repo (or when pushing the context is blocked). A stage-context
    initContainer materializes the ConfigMap into an emptyDir with `cp -L` so BuildKit reads
    REAL files, not the ConfigMap projection (a "..data" dir plus per-key symlinks, which would
    drag "..data" into `COPY .` and jitter the context hash). Constraints (ConfigMap-imposed):
    keys are FLAT (no sub-dirs, so no nested COPY paths), the whole context must fit ~1 MiB, and
    files land 0644 (chmod in the Dockerfile if a script needs +x). Trade-off: no repo#ref in
    the Job spec means the pushed image has no auditable source and git-side controls (review,
    branch protection) are bypassed — and anyone who can create a ConfigMap in the builder
    namespace can push an arbitrary image to ECR through the builder SA, so treat that
    ConfigMap-create permission as ECR-push-equivalent (RBAC). Prefer an immutable ConfigMap so
    a tag's meaning cannot drift mid-build.

Misconfiguration is a render-time error, never a build from the wrong context (this chart's
"no silent no-op" discipline): an unknown contextSource, a contextConfigMap set under git, a
missing contextConfigMap under configMap, or an unsafe filename/contextSubPath all fail loud.

Called with a dict = the imageBuild values plus the caller's identity (jobName, and for a git
context, contextSubPath). Canonical caller form (see image-build-ddp-sample.yaml):
  {{- $args := deepCopy .Values.imageBuild -}}
  {{- $_ := set $args "jobName" "build-foo" -}}
  {{- $_ := set $args "contextSubPath" "path/to/foo" -}}   # git context only
  {{- include "image-builder.job" $args }}
A generic caller that takes jobName from values (for images with no fixed identity, e.g. a
ConfigMap context) is image-build-custom.yaml.
*/ -}}
{{- define "image-builder.job" -}}
{{- $ib := . -}}
{{- if not $ib.repository }}{{ fail "imageBuild.repository is required (the ECR repo URI, e.g. terraform output -raw <image>_ecr_url)" }}{{- end }}
{{- if not $ib.jobName }}{{ fail "image-builder.job: jobName is required — the caller supplies its image identity" }}{{- end }}
{{- /* Every value spliced verbatim into a buildctl arg-list item, the Job name, or a YAML value is
     validated so a stray comma/newline/space (via --set) cannot inject a separate buildctl option
     (e.g. tag "v1,push=false" into type=image,name=...:<tag>,push=true), break the Job name, or
     break the YAML. filename/contextSubPath are validated further below. */ -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" $ib.jobName) }}{{ fail (printf "image-builder.job: jobName must be a DNS-1123 label (lowercase alphanumeric and -), got %q" $ib.jobName) }}{{- end }}
{{- /* The Job is named <jobName>-<tag>, which must be a DNS-1123 label (<=63 chars). Validating the
     COMBINED name at render time catches an uppercase/dotted/underscored/comma'd tag here rather
     than at apply, and the comma check is exactly what stops "v1,push=false" from injecting a
     second option into the type=image,...:<tag>,push=true output arg. */ -}}
{{- $jobFull := printf "%s-%s" $ib.jobName ($ib.tag | toString) }}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" $jobFull) }}{{ fail (printf "the Job name %q (=<jobName>-<tag>) must be a DNS-1123 label (lowercase alphanumeric and -); fix imageBuild.jobName / imageBuild.tag" $jobFull) }}{{- end }}
{{- if gt (len $jobFull) 63 }}{{ fail (printf "the Job name %q exceeds the 63-char DNS-1123 label limit; shorten imageBuild.jobName / imageBuild.tag" $jobFull) }}{{- end }}
{{- if not (regexMatch "^[A-Za-z0-9._/-]+$" $ib.repository) }}{{ fail (printf "imageBuild.repository must be a plain ECR repo URI (no scheme/space/comma), got %q" $ib.repository) }}{{- end }}
{{- /* namespace / serviceAccountName land in YAML values; a stray newline would inject YAML. */ -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" ($ib.namespace | default "image-builder")) }}{{ fail (printf "imageBuild.namespace must be a DNS-1123 label, got %q" $ib.namespace) }}{{- end }}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" ($ib.serviceAccountName | default "image-builder")) }}{{ fail (printf "imageBuild.serviceAccountName must be a DNS-1123 label, got %q" $ib.serviceAccountName) }}{{- end }}
{{- /* Build context source, validated once and reused. An UNKNOWN value must NOT fall through to
     git: a typo like "configmap"/"cm" would silently build from the WRONG context and push a
     wrong image to ECR — the silent-wrong-build this chart forbids. Fail loud. */ -}}
{{- $cs := $ib.contextSource | default "git" }}
{{- if not (or (eq $cs "git") (eq $cs "configMap")) }}{{ fail (printf "imageBuild.contextSource must be \"git\" or \"configMap\", got %q" $cs) }}{{- end }}
{{- $useCM := eq $cs "configMap" }}
{{- if and $useCM (not $ib.contextConfigMap) }}{{ fail "imageBuild.contextConfigMap is required when contextSource=configMap" }}{{- end }}
{{- /* Inverse footgun: a contextConfigMap set while contextSource is still git means the user
     named the ConfigMap but forgot to switch the source — same silent-wrong-build class. */ -}}
{{- if and (not $useCM) $ib.contextConfigMap }}{{ fail "imageBuild.contextConfigMap is set but contextSource is not \"configMap\" (add --set imageBuild.contextSource=configMap, or clear contextConfigMap)" }}{{- end }}
{{- /* Validate the values spliced verbatim into buildctl arg-list items so a stray newline (via
     --set) cannot inject a separate flag / break the YAML. */ -}}
{{- $fn := $ib.filename | default "Dockerfile" }}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" $fn) }}{{ fail (printf "imageBuild.filename must match ^[A-Za-z0-9._-]+$ (a flat filename), got %q" $fn) }}{{- end }}
{{- $subPath := $ib.contextSubPath }}
{{- if not $useCM }}
{{-   if not $subPath }}{{ fail "image-builder.job: contextSubPath is required for a git context (the caller supplies it)" }}{{- end }}
{{-   if not (regexMatch "^[A-Za-z0-9._/-]+$" $subPath) }}{{ fail (printf "contextSubPath must match ^[A-Za-z0-9._/-]+$, got %q" $subPath) }}{{- end }}
{{- /* gitRepo and gitRef are spliced into the buildctl git context arg. */ -}}
{{-   if not (regexMatch "^[A-Za-z0-9._/-]+$" ($ib.gitRepo | default "github.com/littlemex/distributed-ai.git")) }}{{ fail (printf "imageBuild.gitRepo must be a host/path with no scheme/space/comma, got %q" $ib.gitRepo) }}{{- end }}
{{-   if not (regexMatch "^[A-Za-z0-9._/-]+$" ($ib.gitRef | default "main")) }}{{ fail (printf "imageBuild.gitRef must match ^[A-Za-z0-9._/-]+$ (a branch/tag/sha), got %q" $ib.gitRef) }}{{- end }}
{{- end }}
{{- /* Registry host = the ECR repo URI up to the first "/" (no scheme, no path). This is the exact
     key BuildKit's auth provider matches on; a scheme prefix would make it miss and push anon. */ -}}
{{- $registry := (splitList "/" $ib.repository) | first }}
{{- /* Derive the ECR region from the host (<account>.dkr.ecr.<region>.amazonaws.com) so the login
     token's region always matches the target registry — no separate region knob to forget/mismatch.
     Fall back to imageBuild.region only for a non-standard host that doesn't parse. */ -}}
{{- $hostParts := splitList "." $registry }}
{{- /* ternary evaluates BOTH branches, so `index $hostParts 3` would still throw on a short host;
     guard the index with if/else instead. */ -}}
{{- $region := $ib.region | default "us-west-2" }}
{{- if and (ge (len $hostParts) 6) (eq (index $hostParts 2) "ecr") }}{{ $region = index $hostParts 3 }}{{- end }}
apiVersion: batch/v1
kind: Job
metadata:
  # Tag is part of the name: a new tag is a new Job; re-running the same tag needs an explicit
  # delete (kubectl apply on a Complete Job of the same name is a harmless no-op).
  name: {{ $ib.jobName }}-{{ $ib.tag }}
  namespace: {{ $ib.namespace | default "image-builder" }}
spec:
  backoffLimit: 1
  # Reap the finished Job after a day so repeated workshop runs don't pile up.
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      serviceAccountName: {{ $ib.serviceAccountName | default "image-builder" }}
      restartPolicy: Never
      nodeSelector:
        # BuildKit here does NOT cross-build (rootless image ships no QEMU/binfmt). Pin amd64 so a
        # Graviton node can't produce an arm64 image that fails `exec format error` on the amd64
        # GPU/CPU nodes that run it. (--opt platform=linux/amd64 below is a redundant fail-fast.)
        kubernetes.io/arch: amd64
        {{- if (($ib.dedicatedPool).enabled) }}
        # Large-image builds land on the dedicated NVMe-RAID0 builder pool (image-builder.tf,
        # image_builder_dedicated_pool=true), whose big local disk fits a tens-of-GB build.
        node-role: image-builder
        {{- else }}
        # Small images (e.g. ddp-sample) build on the shared CPU pool.
        node-role: cpu
        {{- end }}
      {{- if (($ib.dedicatedPool).enabled) }}
      tolerations:
        - { key: workload, value: image-build, operator: Equal, effect: NoSchedule }
      {{- end }}
      # ── initContainer: turn Pod Identity creds into an ECR login token + a config.json ────────
      # Runs as UID 1000 so the file it writes is readable by the (also-1000) rootless builder.
      # HOME=/tmp gives the AWS CLI a writable cache dir; AWS_REGION is required for ecr.
      initContainers:
        - name: ecr-login
          image: {{ $ib.awsCliImage | default "public.ecr.aws/aws-cli/aws-cli:2.31.13@sha256:dcaa51e37b4b681f77e6fefe0e9702b7dc0c5e2ed035ba31775575144af7463c" }}
          command: ["/bin/sh","-c"]
          args:
            - |
              set -e
              export HOME=/tmp
              TOKEN=$(aws ecr get-login-password --region "{{ $region }}")
              # config.json auths key is the bare registry HOST (no https://, no path). The value is
              # base64("AWS:<token>") with NO trailing newline and NO line wrapping — echo/-w76 both
              # corrupt it silently (valid JSON, broken auth). printf + base64 -w0 is the safe form.
              AUTH=$(printf 'AWS:%s' "$TOKEN" | base64 -w0)
              mkdir -p /dockercfg
              printf '{"auths":{"%s":{"auth":"%s"}}}' "{{ $registry }}" "$AUTH" > /dockercfg/config.json
              echo "wrote /dockercfg/config.json for {{ $registry }}"
          env:
            - { name: AWS_REGION, value: "{{ $region }}" }
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
          volumeMounts:
            - { name: dockercfg, mountPath: /dockercfg }
{{- if $useCM }}
        # ── initContainer: materialize the ConfigMap into REAL files for the build context ────────
        # A ConfigMap volume is "..data" + per-key symlinks, not plain files; cp -L dereferences the
        # key symlinks into the /workspace emptyDir. The `* .[!.]*` glob copies normal keys AND
        # dotfile keys like .dockerignore, while skipping the projection dirs "..data"/"..<ts>" (they
        # start with two dots). `--` guards a key that begins with "-". The Dockerfile existence check
        # turns a missing/typo'd Dockerfile (or one dropped as a "..<x>" key) into a loud failure here
        # rather than a confusing buildkit "no Dockerfile" later. UID 1000 so the rootless builder reads.
        # Reuses the aws-cli image (already pulled by ecr-login on this node) — it only needs sh/cp,
        # so sharing that pinned image avoids a second image pull rather than adding a busybox.
        - name: stage-context
          image: {{ $ib.awsCliImage | default "public.ecr.aws/aws-cli/aws-cli:2.31.13@sha256:dcaa51e37b4b681f77e6fefe0e9702b7dc0c5e2ed035ba31775575144af7463c" }}
          command: ["/bin/sh","-c"]
          args:
            - |
              set -e
              cd /cm
              for f in * .[!.]*; do [ -e "$f" ] || continue; cp -L -- "$f" /workspace/; done
              [ -f "/workspace/$FN" ] || { echo "ERROR: Dockerfile '$FN' not found among ConfigMap keys (keys are flat; keys starting with '..' are skipped)"; ls -la /workspace; exit 1; }
              echo "staged context files:"; ls -la /workspace
          env:
            - { name: FN, value: "{{ $fn }}" }
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
          volumeMounts:
            - { name: cmsrc, mountPath: /cm }
            - { name: workspace, mountPath: /workspace }
{{- end }}
      containers:
        - name: buildkit
          # Rootless BuildKit, pinned by digest for reproducibility (same discipline as the old
          # Kaniko pin). Override with imageBuild.buildkitImage to bump.
          image: {{ $ib.buildkitImage | default "moby/buildkit:v0.24.0-rootless@sha256:995077ff90af1afff56ff23018699d7511d122b2b111041f2011bd12afd5c0fe" }}
          # Override the image's buildkitd entrypoint: run one-shot via the daemonless wrapper.
          command: ["buildctl-daemonless.sh"]
          args:
            - build
            - --frontend=dockerfile.v0
{{- if $useCM }}
            # NON-git context: build from the /workspace emptyDir the stage-context initContainer
            # filled with real files copied out of the ConfigMap (see that initContainer for why cp -L).
            - --local
            - context=/workspace
            - --local
            - dockerfile=/workspace
            - --opt
            - filename={{ $fn }}
{{- else }}
            # git context; "#<ref>:<subdir>" makes <subdir> the build root — exact equivalent of
            # Kaniko's --context-sub-path, so the Dockerfile's relative COPYs are unchanged. Must be
            # https:// (GitHub removed the git:// protocol in 2022).
            - --opt
            - context=https://{{ $ib.gitRepo | default "github.com/littlemex/distributed-ai.git" }}#{{ $ib.gitRef | default "main" }}:{{ $subPath }}
            - --opt
            - filename={{ $fn }}
{{- end }}
            # Fail-fast if somehow scheduled on a non-amd64 node (no cross-build here).
            - --opt
            - platform=linux/amd64
            {{- /* Optional Docker build-args (e.g. pin a version without editing the Dockerfile). Each
                 becomes one --opt build-arg:KEY=VALUE. Empty by default, so this renders nothing.
                 KEY is constrained to an env-var-like identifier, and the whole build-arg:KEY=VALUE
                 is emitted as ONE quoted scalar so a VALUE containing a newline / ":" / "#" cannot
                 inject a separate arg-list item or break the YAML. */ -}}
            {{- range $k, $v := ($ib.buildArgs | default dict) }}
            {{-   if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" $k) }}{{ fail (printf "imageBuild.buildArgs key %q must be an identifier (^[A-Za-z_][A-Za-z0-9_]*$)" $k) }}{{- end }}
            - --opt
            - {{ printf "build-arg:%s=%s" $k ($v | toString) | quote }}
            {{- end }}
            # WITHOUT push=true the build "succeeds" but nothing lands in ECR — the classic silent
            # no-op. name is the full ECR ref.
            - --output
            # zstd (opt-in): only worth it when the measurement in the image-cache chapter shows
            # decompression, not download, dominating a cold pull. oci-mediatypes is required —
            # zstd layers need the OCI descriptor types, and the Docker v2 manifest cannot express
            # them. force-compression is deliberately NOT set: it would recompress the external
            # base layers too, changing their digests and destroying sharing and cache hits across
            # every image built on that base. Without it only the layers this build adds are zstd,
            # which is the mixed form that keeps both.
            - type=image,name={{ $ib.repository }}:{{ $ib.tag }},push=true{{ if $ib.zstd }},compression=zstd,oci-mediatypes=true{{ end }}
          env:
            # In a K8s Pod the worker cannot unshare the PID namespace; without this flag buildkitd
            # fails to start. Trade-off (build shares buildkitd's PID ns) is fine for a single-shot,
            # own-repo build.
            - { name: BUILDKITD_FLAGS, value: "--oci-worker-no-process-sandbox" }
            # BuildKit reads auth from the config.json in this DIRECTORY (not a file path).
            - { name: DOCKER_CONFIG, value: /dockercfg }
          securityContext:
            # Rootless: non-privileged, no CAP_SYS_ADMIN. seccomp Unconfined is required for the
            # user-namespace/overlayfs path (this violates PSA baseline/restricted — the
            # image-builder namespace must stay unlabeled/privileged; see the book note).
            runAsUser: 1000
            runAsGroup: 1000
            runAsNonRoot: true
            seccompProfile:
              type: Unconfined
          resources:
            requests:
              cpu: {{ $ib.cpu | default "2" | quote }}
              # Overridable, like cpu and ephemeralStorage. It was previously hardcoded at 8Gi,
              # which silently capped what this builder could build: an image whose Dockerfile
              # compiles anything substantial (e.g. a CUDA extension against torch) is OOMKilled
              # with exit 137 and NO buildkit log, because the container is SIGKILLed rather than
              # failing a build step. Raise imageBuild.memory for such images. Default unchanged.
              memory: {{ $ib.memory | default "8Gi" }}
              # Peak build disk ~= pushed image size x4-5 (base unpacked + snapshot, uncompressed);
              # the buildkit state emptyDir counts against this too. 30Gi fits ddp-sample on the
              # shared CPU pool's 150Gi root. For a large image raise imageBuild.ephemeralStorage AND
              # set dedicatedPool.enabled=true, else the Job stays Pending or is Evicted mid-build.
              ephemeral-storage: {{ $ib.ephemeralStorage | default "30Gi" }}
            limits:
              memory: {{ $ib.memory | default "8Gi" }}
              ephemeral-storage: {{ $ib.ephemeralStorage | default "30Gi" }}
          volumeMounts:
            - { name: dockercfg, mountPath: /dockercfg }
            # BuildKit's snapshot/state. On the container overlayfs it would fall back to the slow
            # native snapshotter (overlay-on-overlay is not allowed); an emptyDir avoids that.
            - { name: buildkitd, mountPath: /home/user/.local/share/buildkit }
{{- if $useCM }}
            # The staged build context (real files, filled by the stage-context initContainer).
            - { name: workspace, mountPath: /workspace }
{{- end }}
      volumes:
        - { name: dockercfg, emptyDir: {} }
        - { name: buildkitd, emptyDir: {} }
{{- if $useCM }}
        # cmsrc = the raw ConfigMap (symlink projection); workspace = the flattened real-file
        # context the builder reads. Prefer an immutable ConfigMap so it can't change mid-build.
        - name: cmsrc
          configMap:
            name: {{ $ib.contextConfigMap | quote }}
        # sizeLimit tracks the ConfigMap budget — the staged context is a copy of a <=1 MiB source.
        - { name: workspace, emptyDir: { sizeLimit: 2Mi } }
{{- end }}
{{- end -}}
