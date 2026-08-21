# Qwen3.8-27B on EKS — vLLM serving + self-hosted agents

Reference deployment of `Qwen/Qwen3.8-27B` on EKS with vLLM (FP8 + MTP speculative decoding +
YaRN 1M context), plus four agents — opencode, qwen-code, Hermes, OpenClaw — running against the
self-hosted backend, and a Bedrock `web_search` tool wired in over EKS Pod Identity. SGLang with
DFLASH2 speculative decoding is available as an opt-in faster engine.

**Status**

| Path | State | Notes |
|---|---|---|
| vLLM (default) | verified | FP8 + MTP(3) + YaRN 1M; tool-calling, image, video, 1M retrieval checked. Single-user TPOT ≈ 9.4 ms (c=1, in512/out256, `--ignore-eos`). |
| SGLang (opt-in) | experimental | DFLASH2 + FP8 + fp8 KV + YaRN 1M. Promotion criteria not yet met (0/4) — see [`serving/README.md`](serving/README.md). |

The base cluster is not modified. Everything here is removable with the teardown command; nothing
is added to the Terraform-managed `infra/` layer.

## Architecture

```
Karpenter NodePool (g6e.12xlarge, L40S x4)
  └─ vLLM (FP8 + MTP + YaRN 1M)   ── OpenAI-compatible :8000 ──┐
                                                              │  Service alias: qwen-serving
CPU pods: opencode / qwen-code / Hermes / OpenClaw ───────────┘  (agents always target the alias)
  └─ bedrock-websearch tool  ── EKS Pod Identity ─▶ Amazon Bedrock web_search
```

## Prerequisites

Bring these yourself:

| Requirement | Detail |
|---|---|
| EKS cluster + Karpenter | reachable via a kubeconfig context; Karpenter provisions the GPU node |
| GPU EC2NodeClass | the pool references a Karpenter EC2NodeClass named `gpu-ddp` (subnet/SG/AMI discovery); edit `serving/pool/nodepool-gpu-l40s.yaml` if yours differs |
| Bedrock role | an IAM role the agents assume for `web_search`, passed as `QWEN_BEDROCK_ROLE_ARN`; grant it Bedrock access and enable model access in `QWEN_BEDROCK_REGION` |
| GPU quota | `Running On-Demand G and VT instances` ≥ 48 vCPU (g6e.12xlarge) |
| CLI tools | `kubectl`, `aws` CLI v2, `helm` 3.x, `python3` |
| Caller IAM | `eks:*PodIdentityAssociation*`, `iam:PassRole`, `sts:GetCallerIdentity` |

This reference assumes a **dedicated cluster**: the GPU pool is part of the workload, and `deploy.sh
--down` removes that cluster-scoped Karpenter NodePool. On a shared cluster, delete only the
namespaced resources (`kubectl delete namespace $QWEN_NAMESPACE` plus the Pod Identity associations)
so you do not remove a pool other workloads rely on.

`deploy.sh` preflight checks and reports on these: the EKS Pod Identity agent add-on, the Bedrock
role and its model access, the availability zone offering g6e, and the target namespace.

## Quickstart

```bash
git clone <this repo> && cd <repo>/2026-08-19-qwen3-8-27b-vllm-eks
./scripts/deploy.sh                 # default engine vLLM; prompts to confirm the target cluster
install -m 755 <(curl -fsSL <commit-pinned-raw-url>/client/qwen-agents.sh) ~/.local/bin/qwen-agents
qa opencode                         # qa = qwen-agents; drops into the opencode TUI
```

`deploy.sh` reads the target context from `$QWEN_KUBE_CONTEXT`, defaulting to the current kubeconfig
context, and shows the context, cluster ARN, and account for confirmation before it changes anything.
First run takes roughly 10-15 minutes: node provisioning, image pull, weight download, and warmup. It
ends with a smoke check that gates success. Run `./scripts/deploy.sh --engine sglang` for the opt-in
engine after building its image — see [`serving/README.md`](serving/README.md).

## Cost and cleanup

The GPU node is billed per hour while running (g6e.12xlarge, on-demand). Tear everything down when
finished:

```bash
./scripts/deploy.sh --down          # removes agents, serving, the GPU pool, and the alias
```

## Layout

```
serving/     model-serving reference: vllm/ (default) and sglang/ (opt-in) engines, shared pool,
             model facts, and the qwen-serving Service alias
agents/      opencode / qwen-code / hermes / openclaw (each self-contained) + shared tools/
client/      qwen-agents.sh launcher (keyless kubectl exec), port-forward.sh
scripts/     deploy.sh (one-shot bring-up and teardown), smoke.py, lint.sh
experiments/ benchmarks and rejected explorations (concurrency sweep, FP8 latency, SGLang/DFLASH, MTP)
```

## Configuration (environment)

| Variable | Source / default | Overridable |
|---|---|---|
| `QWEN_KUBE_CONTEXT` | current kubeconfig context | yes (deploy confirms) |
| `QWEN_NAMESPACE` | `qwen` | yes |
| `QWEN_REGION` | derived from the context | yes |
| `QWEN_BEDROCK_REGION` | `$QWEN_REGION` | yes |
| account id | `aws sts get-caller-identity` | no (derived, verified) |
| `QWEN_BEDROCK_ROLE_ARN` | — | yes (account is verified against the caller) |

## Access

Agents run in CPU pods and are entered with `kubectl exec` (keyless, no ssh). See
[`ACCESS.md`](ACCESS.md) for per-agent usage and [`agents/README.md`](agents/README.md) for what
each agent is. Licensed under the repository `LICENSE`.
