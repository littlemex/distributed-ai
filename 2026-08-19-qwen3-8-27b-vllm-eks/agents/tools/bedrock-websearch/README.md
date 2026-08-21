# bedrock-websearch — Bedrock Web Search as a tool for self-hosted agents

A thin wrapper that exposes Amazon Bedrock's server-side `web_search` tool as a plain
search tool, so a self-hosted model (Qwen3.8-27B on vLLM) stays the agent's "brain" while
Bedrock does the actual web search. One file, two entrypoints, `botocore` the only dep.

## Why

Bedrock web search only works on the **Responses API** with **Bedrock's own OpenAI models**
(`openai.gpt-5.6-*`), via `bedrock-mantle.<region>.api.aws/openai/v1/responses`, SigV4-signed
(service `bedrock`), regions us-east-1 / us-east-2 / us-west-2. It cannot be attached to the
Qwen agent's own tool-calling. This wrapper makes it a callable tool instead, so any agent
can use it without switching its model off Qwen.

## Entrypoints

- CLI: `python3 bedrock_websearch.py "<query>"` -> prints answer + source URLs.
- MCP: `python3 bedrock_websearch.py --mcp` -> stdio JSON-RPC MCP server, tool `web_search`.

Env: `BEDROCK_WS_REGION` (default us-east-1), `BEDROCK_WS_MODEL` (default openai.gpt-5.6-sol),
`BEDROCK_WS_EXTERNAL` (default true). Auth: default AWS credential chain (env / profile /
EKS Pod Identity), no API key.

## opencode (verified)

Add the MCP to `opencode.json` (see `opencode.mcp.example.json`), then the Qwen agent calls it:

```
opencode run --pure --auto --model vllm-local/Qwen/Qwen3.8-27B \
  "Use the web_search tool to find the latest vLLM release version and the source URL."
# -> v0.27.1 — https://github.com/vllm-project/vllm/releases   (Qwen brain + Bedrock search)
```

Verified end to end: the Qwen agent invoked `bedrock-websearch_web_search` and returned a
grounded answer with a citation. The opencode process needs AWS credentials in its environment
(the MCP subprocess inherits them).

## openclaw (verified, deployed)

The pinned OpenClaw build (2026.3.1) has no `openclaw mcp` subcommand, so this tool is wired
via the agent's shell tool plus an `AGENTS.md` that teaches the agent to use it:

- `bedrock_websearch.py` and `AGENTS.md` are mounted from a ConfigMap at `/opt/tools`
  (see `../../openclaw/openclaw.yaml`); the start command copies `AGENTS.md` into the agent
  workspace, so the agent auto-runs the tool for "latest / research" questions.
- AWS credentials come from an **EKS Pod Identity association** binding the `openclaw`
  ServiceAccount to an IAM role with Bedrock permissions (no static keys). The wrapper reads
  those credentials from the Pod Identity container endpoint (stdlib, no botocore in the image).
- On an OpenClaw build that has `openclaw mcp add`, register it as a stdio MCP instead
  (`--command python3 --args /opt/tools/bedrock_websearch.py --args --mcp`).

Verified: `openclaw agent -m "What is the newest stable Go version? Research and cite the source."`
auto-searches via Bedrock and answers with sources — Qwen brain, Bedrock search, in-pod, keyless.

## Cost / caveats

- Each search-grounded call is a Bedrock GPT call and injects the web context, so input tokens
  are large (~30k observed per call). Billed to the account (`billing.payer=developer`).
- Responses API + `web_search` only; chat/completions rejects the tool.
