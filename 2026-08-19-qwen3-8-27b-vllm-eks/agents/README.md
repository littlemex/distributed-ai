# agents

Four agents run in CPU pods against the self-hosted Qwen backend (the `qwen-serving` Service alias,
OpenAI-compatible on `:8000`). Each subdirectory is one agent and is self-contained: a
`deployment.yaml`, a `sa.yaml` (its ServiceAccount, bound to the Bedrock role by an EKS Pod Identity
association at deploy time), and the agent's config. `tools/` is a shared tool, not an agent.

| Agent | What it is | Multimodal | Notes |
|---|---|---|---|
| opencode | coding CLI (OpenAI-compatible provider) | image | `opencode.pod.json` (in-cluster, MCP tool); `opencode.local.json.example` for running opencode on a laptop. No video path. |
| qwen-code | Qwen's gemini-cli fork (`qwen`) | image, video | `settings.json`: `openai` auth type, `security.auth.selectedType: openai`; `modelProviders.openai[].generationConfig.modalities` enables image/video for a self-hosted model name. |
| hermes | general-purpose assistant CLI | image | config lives at `/opt/data/config.yaml` (set via `hermes config set`); model reference must be bare; context window ≥ 64K. |
| openclaw | browser agent + gateway/cron | — | onboarded as a `custom-api-key` OpenAI-compatible provider; Control UI on a background port-forward. |

## tools/bedrock-websearch

A stdlib-only `web_search` tool (CLI + stdio MCP server) that calls Amazon Bedrock and returns a
grounded answer with source URLs. It authenticates with AWS via EKS Pod Identity using a
fixed-endpoint fallback, so it works even when the host agent does not pass container environment to
its MCP subprocess.

## Access

Enter an agent with the launcher (`qa opencode`, `qa qwen-code`, `qa hermes`, `qa openclaw`) or raw
`kubectl exec`. Push a local image or video into a pod with `qa push <file> <agent>`. See
[`../ACCESS.md`](../ACCESS.md).
