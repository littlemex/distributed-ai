# Agents

Three agents run in CPU pods against the self-hosted FreeToken backend, reached through the
`freetoken-serving` Service alias on port 1919. Because they target the alias rather than a
model-specific Service, switching the served model needs no change here — `scripts/deploy.sh`
renders each agent's model id and context window from the active profile's values file, so an agent
can never advertise a model or a context length the engine is not actually serving.

| Agent | CLI | Backend wiring |
|---|---|---|
| opencode | `opencode` | `opencode.json` provider `freetoken-local`, `@ai-sdk/openai-compatible` against the alias |
| hermes | `hermes` | `OLLAMA_BASE_URL` pointed at the alias (OpenAI-compatible) |
| openclaw | `openclaw` | `--custom-base-url` at the alias, provider id `freetoken-eks`, model from `$FREETOKEN_MODEL` |

Enter one with the launcher (`./client/ft-agents.sh opencode`) or with raw
`kubectl exec -it deploy/opencode -- bash -lc opencode`. Access is keyless: `kubectl exec`
authenticates with your existing kubeconfig, so there is no sshd and no key to distribute.

## The shared S3 Files volume at `/shared`

Every agent pod mounts the same S3 Files PVC (`freetoken-model-cache`) that the serving pod reads
its checkpoint from, at `/shared`. The volume is `ReadWriteMany`, so all agents and the serving pod
hold it simultaneously.

**What it is good for.** Reading large artifacts in place, with no per-pod download and no local
disk cost. The checkpoint itself is the obvious case — an agent can inspect a model's `config.json`
or tokenizer without pulling 160 GB — but anything a producer writes to the bucket becomes readable
by every agent at once, which is what makes it a shared context store rather than three
independent scratch disks.

**What it is not.** It is not a shared writable workspace. The mount is read-only twice over: each
pod sets `readOnly: true`, and the PV itself pins `-o ro` so writes fail at the mount layer no
matter what a pod requests. That is deliberate — a 160 GB checkpoint that a serving pod is mid-read
on must not be mutable by an agent — but it does mean agents cannot use `/shared` to pass files to
each other.

The read-only mount option is hardcoded in the shared library this consumes
(`infra/eks/charts/s3files-lib`), so a genuinely writable shared workspace would need that library
to parameterize `mountOptions` rather than a change here. Until then, producers write through the
S3 API (`storage/sync-checkpoint.sh` is the worked example) and consumers read the file system.

**One AZ.** The file system has a single mount target and NFS DNS resolves per-AZ, so the PV's
`nodeAffinity` pins every pod that mounts it — agents included — into that one AZ. Karpenter will
provision a CPU node there if none exists yet.

**First access can lie.** S3 Files imports object metadata lazily, so opening a deep path before
walking its parents can return `ENOENT` for an object that is present in the bucket. Walk the
directory (`ls`, `find`) before opening files. The serving chart does this in an initContainer for
exactly this reason.

## Web search

`tools/bedrock-websearch/` wraps Bedrock's `web_search` as a callable tool over MCP, so a
self-hosted model keeps being the agent's brain while search goes to Bedrock. It is opt-in and
authenticated with EKS Pod Identity; see that directory's README.
