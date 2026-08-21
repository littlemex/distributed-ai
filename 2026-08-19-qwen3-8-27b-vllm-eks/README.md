# Qwen3.8-27B on EKS — vLLM serving + self-hosted agents

Reference deployment of `Qwen/Qwen3.8-27B` on EKS. vLLM serves the model with FP8 weights, a
YaRN-extended 1M context, and MTP speculative decoding. MTP, Multi-Token Prediction, is a
self-speculative method that reuses the model's built-in 1-layer MTP head, so it needs no separate
draft model. Four agents — opencode, qwen-code, Hermes, and OpenClaw — run against the self-hosted
backend, and a Bedrock `web_search` tool is wired in over EKS Pod Identity. SGLang with DFLASH2, a
separate-draft speculative-decoding method, is available as an opt-in faster engine.

**Status**

| Path | State | Notes |
|---|---|---|
| vLLM (default) | verified | FP8 + MTP(3) + YaRN 1M; tool-calling, image, and video checked. Single-user TPOT ≈ 9.5 ms at short context (c=1, in512/out256, max-model-len 8192, `--ignore-eos`); TPOT rises at the full 1M context. 1M retrieval is not RULER-evaluated. |
| SGLang (opt-in) | experimental | DFLASH2 + FP8 + fp8 KV + YaRN 1M. Promotion criteria not yet met (0/4) — see [`serving/README.md`](serving/README.md). |

The base cluster is not modified. Everything here is removable with the teardown command; nothing
is added to the Terraform-managed `infra/` layer.

## Architecture

```mermaid
flowchart LR
  P["Karpenter NodePool<br/>g6e.12xlarge — L40S x4"] --> V["vLLM engine<br/>FP8 + MTP + YaRN 1M<br/>OpenAI-compatible :8000"]
  V --> S["qwen-serving<br/>Service alias"]
  AG["CPU pods<br/>opencode / qwen-code<br/>Hermes / OpenClaw"] --> S
  AG --> B["bedrock-websearch<br/>EKS Pod Identity → Bedrock web_search"]
```

The agents target the `qwen-serving` alias, not an engine-specific Service, so switching the active
engine needs no change on the agent side.

## Prerequisites

Bring these yourself:

| Requirement | Detail |
|---|---|
| EKS cluster + Karpenter | reachable via a kubeconfig context; Karpenter provisions the GPU node |
| GPU EC2NodeClass | the pool references a Karpenter EC2NodeClass named `gpu-ddp` (subnet/SG/AMI discovery); edit `serving/pool/nodepool-gpu-l40s.yaml` if yours differs |
| Bedrock role (web_search only) | needed only if you enable the opt-in `web_search` tool with `--websearch`. Supply an existing role via `QWEN_BEDROCK_ROLE_ARN`, or let `deploy.sh` create one for you with `AmazonBedrockFullAccess`. Enable Bedrock model access in `QWEN_BEDROCK_REGION` either way |
| GPU quota | `Running On-Demand G and VT instances` ≥ 48 vCPU (g6e.12xlarge) |
| CLI tools | `kubectl`, `aws` CLI v2, `helm` 3.x, `python3` |
| Caller IAM | `eks:*PodIdentityAssociation*`, `iam:PassRole`, `sts:GetCallerIdentity` |

The GPU pool is a cluster-scoped Karpenter NodePool. `deploy.sh --down` keeps it by default and only
removes it with `--purge-pool`, so teardown does not disrupt a pool other workloads share. On a
shared cluster, prefer deleting just the namespaced resources: `kubectl delete namespace
$QWEN_NAMESPACE` plus the Pod Identity associations.

`deploy.sh` shows the target context, cluster, and account for confirmation before it changes
anything, creates the namespace if it is absent, and for the SGLang engine checks that its image
exists. It does not verify the Pod Identity add-on, the Bedrock role, or the g6e zone offering, so
bring those per the table above.

## Quickstart

```bash
curl -fsSL https://raw.githubusercontent.com/littlemex/distributed-ai/f3e58acb86080428b1cfe9e943e2d4566c733082/2026-08-19-qwen3-8-27b-vllm-eks/client/install.sh | bash
qa opencode
```

One command deploys the whole stack and installs the `qa` launcher on your PATH — no git clone and
no manual setup. `install.sh` fetches this reference at a pinned ref, runs `deploy.sh`, installs
`qa`, and adds `~/.local/bin` to your PATH if it is missing. `https://raw.githubusercontent.com/littlemex/distributed-ai/f3e58acb86080428b1cfe9e943e2d4566c733082/2026-08-19-qwen3-8-27b-vllm-eks` is the raw
GitHub URL pinned to a commit, for example
`https://raw.githubusercontent.com/<owner>/<repo>/<full-sha>/2026-08-19-qwen3-8-27b-vllm-eks`.

Deploy flags after `-- ` are forwarded to `deploy.sh`, so the whole run is one shot:

```bash
curl -fsSL https://raw.githubusercontent.com/littlemex/distributed-ai/f3e58acb86080428b1cfe9e943e2d4566c733082/2026-08-19-qwen3-8-27b-vllm-eks/client/install.sh | bash -s -- --websearch
curl -fsSL https://raw.githubusercontent.com/littlemex/distributed-ai/f3e58acb86080428b1cfe9e943e2d4566c733082/2026-08-19-qwen3-8-27b-vllm-eks/client/install.sh | bash -s -- --skip-gpu --websearch
curl -fsSL https://raw.githubusercontent.com/littlemex/distributed-ai/f3e58acb86080428b1cfe9e943e2d4566c733082/2026-08-19-qwen3-8-27b-vllm-eks/client/install.sh | bash -s -- --engine sglang
curl -fsSL https://raw.githubusercontent.com/littlemex/distributed-ai/f3e58acb86080428b1cfe9e943e2d4566c733082/2026-08-19-qwen3-8-27b-vllm-eks/client/install.sh | bash -s -- --no-deploy
```

The only env you may set is `QWEN_NAMESPACE`, which defaults to `qwen`, and `QWEN_KUBE_CONTEXT`,
which defaults to the current context; the region and cluster are auto-derived from the context's
EKS ARN. Put any env on `bash`, not `curl`, since a variable before `curl` is lost:
`curl -fsSL <raw>/client/install.sh | QWEN_NAMESPACE=trial bash -s -- --websearch`. The installer
records the resolved context and namespace so `qa` targets the same place afterwards. For a private
repo the initial `curl` needs a `GITHUB_TOKEN`, and `QWEN_REPO` / `QWEN_REF` override the source.
First run takes roughly 10-15 minutes for node provisioning, image pull, weight download, and warmup,
and ends with a smoke check. The Bedrock `web_search` tool is off unless you pass `--websearch`; with
it and no `QWEN_BEDROCK_ROLE_ARN`, a Bedrock role with `AmazonBedrockFullAccess` is created for you. `--engine
sglang` needs a prebuilt image, described in [`serving/README.md`](serving/README.md). If your cluster
already has a compatible GPU NodePool and you do not want this reference to apply its own, add
`--skip-gpu` (alias of `--skip-pool`); it composes with `--websearch`, so `--skip-gpu --websearch`
deploys serving and the agents with web search in one shot without touching the pool.

## Cost and cleanup

The GPU node is billed per hour while running (g6e.12xlarge, on-demand). Tear everything down when
finished:

```bash
./scripts/deploy.sh --down
```

This removes the Deployments for both engines and all four agents, the `qwen-serving` alias, and the
Pod Identity associations. It **keeps** the cluster-scoped GPU NodePool by default, since it is
shared; add `--purge-pool` to remove it too (only on a dedicated cluster). ServiceAccounts,
ConfigMaps, and the namespace remain until you delete the namespace. A Bedrock role that
`--websearch` auto-created is not deleted by teardown; when you no longer need it, detach the managed
policy and delete the role: `aws iam detach-role-policy --role-name qwen-agents-websearch
--policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess` then `aws iam delete-role --role-name
qwen-agents-websearch`.

## Layout

```
serving/     charts/ and values/ for the vLLM engine (default), sglang/ for the opt-in engine,
             the shared GPU pool, model facts, and the qwen-serving Service alias
agents/      opencode / qwen-code / hermes / openclaw (each self-contained) + shared tools/
client/      qwen-agents.sh launcher (keyless kubectl exec), port-forward.sh
scripts/     deploy.sh (one-shot bring-up and teardown), smoke.py, lint.sh
experiments/ measurements behind the production settings (FP8, MTP) and the opt-in SGLang/DFLASH
             path (concurrency sweep, FP8 latency, SGLang/DFLASH tuning, MTP)
```

## Configuration (environment)

| Variable | Source / default | Overridable |
|---|---|---|
| `QWEN_KUBE_CONTEXT` | current kubeconfig context | yes (deploy confirms) |
| `QWEN_NAMESPACE` | `qwen` | yes |
| `QWEN_REGION` | derived from the context | yes |
| `QWEN_BEDROCK_REGION` | `us-east-1` (a web_search region) | yes |
| `QWEN_WEBSEARCH` | `0` (off) | yes, or pass `--websearch` |
| account id | `aws sts get-caller-identity` | no (derived from the caller) |
| `QWEN_BEDROCK_ROLE_ARN` | — | optional; only with `--websearch`, auto-created when unset |

## Software versions

| Component | Version |
|---|---|
| vLLM (default engine) | `vllm/vllm-openai:v0.27.1`, unmodified upstream image |
| SGLang (opt-in engine) | built from the upstream commit pinned in `serving/sglang/image/image.env` |
| Model | `Qwen/Qwen3.8-27B`, architecture `Qwen3_5ForConditionalGeneration`, bf16 weights |

The EKS control-plane version and GPU driver are the target cluster's; this reference does not pin
them.

## Access

Agents run in CPU pods and are entered with `kubectl exec` (keyless, no ssh). See
[`ACCESS.md`](ACCESS.md) for per-agent usage and [`agents/README.md`](agents/README.md) for what
each agent is. Licensed under the repository `LICENSE`.
