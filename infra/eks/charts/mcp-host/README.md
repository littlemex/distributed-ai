# mcp-host — host any number of MCP servers on the cluster

One chart that runs the platform's MCP servers on CPU Pods in the `mcp` namespace, driven by a
values list. Each entry in `mcps` renders one Deployment + Service; add an MCP by adding an entry,
no template change. A laptop reaches each over `kubectl port-forward` as a streamable-http endpoint; `kubectl distai-mcp`
does that from the contract below, so a client needs to know neither the names nor the ports.

## Two transports

- **`transport: http`** — the server speaks streamable-http natively (the
  [accelprof](https://github.com/littlemex/accelprof) analysis MCP, the
  [accelprof-knowledge](https://github.com/littlemex/accelprof-knowledge) MCP). The chart runs its
  `command` directly.
- **`transport: stdio`** — a stdio-only MCP wrapped by supergateway (the official MLflow MCP). The
  chart runs `supergateway --stdio "<stdioCommand>" --outputTransport streamableHttp --port <p>`;
  build the bridge image from [`../../images/Dockerfile.mlflow-mcp-bridge`](../../images/Dockerfile.mlflow-mcp-bridge).

## The platform's three MCPs

See [`values-example.yaml`](values-example.yaml): **mlflow** (stdio; run search, needs `mcp-reader`
Pod Identity), **analysis** (http; accelprof image; resolves runs to profile files on the S3 Files
mount, needs the mount + `mcp-reader`), and **knowledge** (http; accelprof-knowledge image; tuning
playbooks, no mount, no credentials). Each is one responsibility; together they cover find →
resolve/analyze → diagnose.

## Per-entry keys

`name`, `image {repository, tag}`, `transport`, `port` (8080), `path` (see below), `command` (http) /
`stdioCommand` (stdio), `env` (map), `serviceAccountName` (a Pod-Identity SA only where AWS
credentials are needed), `s3files {enabled, volumeHandle, mountBase, zone}` (an MCP that reads
traces), and `nodeSelector` / `resources` / `replicas` / `blockImds` overrides. Cluster-wide defaults
live under `defaults`.

## What a client is told

A client has to find these servers without being told which ones exist, so each Service declares
three things and a client reads all three from the object rather than assuming them.

- The label `app.kubernetes.io/component: mcp-host` says the Service is an MCP endpoint. That is what
  a client selects on, within the namespace.
- `spec.ports[0].port` is where it listens. One entry renders one port; a Service with more than one
  is outside what this chart produces, and a client is entitled to read the first.
- The annotation `mcp-host.distai.dev/path` is the MCP path, set only when an entry sets `path`. With
  no annotation a client uses `/mcp`, which is what both transports serve by default: the http servers
  here mount it there, and supergateway's streamable-HTTP path is `/mcp` unless told otherwise.

Changing any of the three means reading the client's discovery and URL construction in the same
change, because the two halves of this contract live in different files.

Holding a forwarded port open is a session, not a service: `kubectl port-forward` ends when the Pod
it selected goes away, and nothing here reconnects. That is deliberate — a client is expected to open
what it needs for as long as it needs it — but it means a long-lived registration pointing at a
forwarded port will eventually point at nothing.

## Security

Every Pod runs non-root with a read-only root filesystem, all capabilities dropped, and a `/tmp`
emptyDir for scratch. By default each Pod gets a NetworkPolicy denying egress to the node IMDS
(`169.254.169.254`) so a hosted MCP cannot steal the node role, while still allowing the Pod
Identity agent — enforced only by a CNI that supports egress NetworkPolicy, so also set the IMDSv2
hop limit to 1 on untrusted-MCP nodes. An MCP that reads traces mounts S3 Files read-only (the
`ro` mount option plus the mount IAM role are the real enforcement; see `s3files-lib`).

## Deploy

```bash
helm dependency build charts/mcp-host
cp charts/mcp-host/values-example.yaml my-values.yaml   # fill <...> from `terraform output`
helm upgrade --install mcp charts/mcp-host -n mcp -f my-values.yaml
```
