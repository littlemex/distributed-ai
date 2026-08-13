# In-cluster image builder — design

Build container images *inside* the cluster with rootless BuildKit and push them to ECR, so a
workshop reader or a CI job needs no local docker/finch. This document covers the **execution**
half (the reusable Helm build Job); the **mechanism** half (ECR repo, IAM role, Pod Identity,
`image-builder` namespace + ServiceAccount) lives in Terraform — see `image-builder.tf` and the
README section "In-cluster image builder".

## Mechanism vs execution

The split mirrors how this module treats the Training Operator (Terraform installs the operator;
the TrainJob is a catalog workload):

- **Mechanism (Terraform, `image-builder.tf`):** the ECR repo, an IAM role scoped to push to it,
  a Pod Identity association, and the `image-builder` namespace + ServiceAccount. It provisions
  *where and as whom* you can build; it never runs a build. A consumer module that builds a
  *different* image grants the builder push to its own repo via
  `image_builder_additional_ecr_repository_arns`.
- **Execution (Helm catalog):** the build Job, rendered with `helm template … | kubectl apply`.

## One reusable Job, thin per-image callers

The Job is a single reusable named template, `experiments.imageBuildJob`
(`charts/experiments/templates/_image-build.tpl`). Each image is a **thin caller** that supplies
only its identity and includes the define; the reference caller is the workshop image,
`charts/experiments/templates/image-build-ddp-sample.yaml`:

```yaml
{{- if .Values.imageBuild.enabled }}
{{- $args := deepCopy .Values.imageBuild -}}
{{- $_ := set $args "jobName" "build-ddp-sample" -}}
{{- $_ := set $args "contextSubPath" (.Values.imageBuild.contextSubPath | default "infra/eks/manifests/ddp-sample") -}}
{{- include "experiments.imageBuildJob" $args }}
{{- end }}
```

To build another image in this chart you do not copy the Job. Either add a dedicated caller like
the above (when the image has a fixed identity worth naming), or use the ready-made generic caller
`image-build-custom.yaml`, which takes `jobName` (and the context) from values so it can build any
image — this is the intended path for a `configMap` context, which by definition has no dedicated
caller. (An image in a *separate* consumer chart keeps its own caller there and grants push via the
Terraform ARN path above.)

### Caller contract

The define reads these keys from the dict it is given (the `imageBuild` values plus the
caller-injected identity):

| key | required | meaning |
|---|---|---|
| `repository` | yes | full ECR repo URI (`terraform output -raw <…>_ecr_url`) |
| `tag` | yes | image tag; also part of the Job name (`<jobName>-<tag>`) |
| `jobName` | yes | caller identity, e.g. `build-ddp-sample` |
| `contextSource` | no (`git`) | `git` or `configMap` |
| `contextSubPath` | git only | build-root sub-dir in the git repo |
| `contextConfigMap` | configMap only | ConfigMap holding the context |
| `filename` | no (`Dockerfile`) | Dockerfile name within the context |
| `gitRepo` / `gitRef` | no | git context source and ref |
| `namespace` / `serviceAccountName` | no | default `image-builder` |
| `region` | no | ECR login region; derived from the repo host when standard |
| `ephemeralStorage` / `zstd` / `dedicatedPool` | no | build sizing / compression / node pool |
| `buildkitImage` / `awsCliImage` | no | digest-pinned image overrides |

## Auth chain (settings-free at IAM)

Pod Identity injects container credentials into the pod (including initContainers). BuildKit
bundles no ECR credential helper, so the `ecr-login` initContainer runs `aws ecr
get-login-password` and writes a `config.json` (auth key = the bare registry host, value =
`base64("AWS:<token>")` with no newline) that BuildKit reads via `DOCKER_CONFIG`. No `docker
login` by hand, no credentials in the repo.

## Build context sources

### git (default)

Clone `gitRepo#gitRef`; the build root is `contextSubPath` (BuildKit's `#<ref>:<subdir>`, the
exact equivalent of Kaniko's `--context-sub-path`). This is the **auditable, reproducible** path:
the Job spec records `repo#ref`, and git-side controls (review, branch protection) apply. **Keep
production images here.**

### configMap

Build from a ConfigMap with **no clone and no git push**, for ad-hoc / experiment images whose
context is not committed to a repo (or when pushing the context is blocked). A `stage-context`
initContainer copies the ConfigMap into an `emptyDir` with `cp -L` so BuildKit reads **real
files**, not the ConfigMap projection (a `..data` dir plus per-key symlinks, which would drag
`..data` into `COPY .` and jitter the context hash). It then verifies the Dockerfile is present
and fails otherwise.

Constraints (imposed by ConfigMap):

- keys are **flat** — no sub-directories, so no nested `COPY` paths;
- the whole context must fit the **~1 MiB** ConfigMap budget (a Dockerfile + small scripts, not
  large or binary context — use the git path for those);
- files land **0644** — `chmod` in the Dockerfile if a script needs `+x`.

Trade-offs (choose knowingly):

- **Provenance:** no `repo#ref` in the Job spec, so the pushed image has no auditable source, and
  git-side controls are bypassed.
- **RBAC:** anyone who can create a ConfigMap in `imageBuild.namespace` can push an arbitrary
  image to ECR through the builder SA via this path — treat ConfigMap-create there as
  **ECR-push-equivalent**.
- **Reproducibility:** editing the ConfigMap and re-running the same tag silently changes what the
  tag means — prefer an **immutable** ConfigMap and bump the tag to rebuild.

Use the generic caller (`image-build-custom.yaml`) for a configMap build, not the ddp-sample
caller — so the Job is named for your image and pushes to your own ECR repo (the ddp-sample caller
fixes both to ddp-sample). Supply `jobName` and your repo:

```bash
kubectl -n image-builder create configmap my-ctx --from-file=Dockerfile --from-file=app.py
kubectl -n image-builder patch configmap my-ctx -p '{"immutable":true}'
helm template exp ./charts/experiments -s templates/image-build-custom.yaml \
  --set imageBuild.enabled=true \
  --set imageBuild.jobName=build-my-app \
  --set imageBuild.repository=$MY_APP_ECR_URL --set imageBuild.tag=v1 \
  --set imageBuild.contextSource=configMap --set imageBuild.contextConfigMap=my-ctx \
  | kubectl apply -f -
```

## Fail-loud validation

Consistent with the chart's "no silent no-op / no silent wrong-build" discipline, misconfiguration
is a **render-time error**, never a build from the wrong context:

- an unknown `contextSource` (e.g. a `configmap` typo) — never a silent git fallback;
- `contextConfigMap` set while `contextSource=git` (named a ConfigMap but forgot to switch source);
- `contextConfigMap` missing when `contextSource=configMap`;
- `filename` / `contextSubPath` outside a safe character set (so a stray value can't inject a
  separate buildctl flag);
- Dockerfile absent from the ConfigMap (caught by `stage-context` before BuildKit starts).

## Reproducibility

BuildKit and the aws-cli helper are pinned by digest. The build is amd64-only (the rootless image
ships no QEMU/binfmt), pinned via `nodeSelector` and a redundant `--opt platform=linux/amd64`.
`push=true` is always set (without it the build "succeeds" but nothing lands in ECR).

## Tests

`infra/eks/tests/cases/image-build.sh` (static layer) renders the chart with `helm template` and
asserts: the ddp-sample git path still renders the same Job (name and git build-context sub-path —
a behavior lock for the book), the configMap path renders the `stage-context` initContainer and
local context, and each fail-loud guard errors. Run with `tests/run-tests.sh --suite baseline`.
