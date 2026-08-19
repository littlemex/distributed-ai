#!/usr/bin/env python3
"""Bedrock Web Search wrapper — expose Amazon Bedrock's server-side `web_search`
tool as a plain search tool that any agent can call, so a self-hosted model
(e.g. Qwen on vLLM) stays the "brain" while Bedrock does the web search.

Two entrypoints:
  - CLI  : `bedrock_websearch.py "<query>"`  -> prints text (answer + sources).
           For openclaw (agent runs it via its exec/bash tool) or any shell caller.
  - MCP  : `bedrock_websearch.py --mcp`      -> stdio MCP server, tool `web_search`.
           For opencode (opencode.json `mcp`) or any MCP client.

Auth uses the default AWS credential chain (env, profile, or EKS Pod Identity),
signed with SigV4 for service `bedrock`. Requires only `botocore` (MCP mode also
needs `mcp`). No API key.

Env:
  BEDROCK_WS_REGION   default us-east-1  (must be us-east-1|us-east-2|us-west-2)
  BEDROCK_WS_MODEL    default openai.gpt-5.6-sol  (bare id; also terra/luna)
  BEDROCK_WS_EXTERNAL default "true"     (external_web_access)
"""
import json
import os
import sys
import urllib.request

DEFAULT_REGION = os.environ.get("BEDROCK_WS_REGION", "us-east-1")
DEFAULT_MODEL = os.environ.get("BEDROCK_WS_MODEL", "openai.gpt-5.6-sol")
EXTERNAL = os.environ.get("BEDROCK_WS_EXTERNAL", "true").lower() in ("1", "true", "yes")


def bedrock_web_search(query, region=None, model=None, external=None):
    """Run one web-search-grounded Responses call. Returns {answer, citations, queries}."""
    import botocore.session
    from botocore.auth import SigV4Auth
    from botocore.awsrequest import AWSRequest

    region = region or DEFAULT_REGION
    model = model or DEFAULT_MODEL
    ext = EXTERNAL if external is None else external

    creds = botocore.session.get_session().get_credentials()
    if creds is None:
        raise RuntimeError("no AWS credentials (env/profile/Pod Identity) found")
    creds = creds.get_frozen_credentials()

    host = f"bedrock-mantle.{region}.api.aws"
    url = f"https://{host}/openai/v1/responses"
    body = json.dumps({
        "model": model,
        "input": query,
        "tools": [{"type": "web_search", "external_web_access": ext}],
    })
    aws_req = AWSRequest(method="POST", url=url, data=body,
                         headers={"Content-Type": "application/json", "Host": host})
    SigV4Auth(creds, "bedrock", region).add_auth(aws_req)

    http_req = urllib.request.Request(url, data=body.encode(),
                                      headers=dict(aws_req.headers.items()), method="POST")
    with urllib.request.urlopen(http_req, timeout=120) as r:
        data = json.load(r)

    if isinstance(data, dict) and data.get("error"):
        raise RuntimeError(f"bedrock error: {data['error']}")

    answers, citations, queries = [], [], []

    def walk(o):
        if isinstance(o, dict):
            if o.get("type") == "web_search_call":
                q = (o.get("action") or {}).get("query")
                if q:
                    queries.append(q)
            if o.get("type") == "output_text":
                answers.append(o.get("text", ""))
                for a in o.get("annotations") or []:
                    if a.get("type") == "url_citation" and a.get("url"):
                        citations.append(a["url"])
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    walk(data)
    # dedupe citations, keep order
    seen = set()
    citations = [c for c in citations if not (c in seen or seen.add(c))]
    return {"answer": "\n".join(a for a in answers if a).strip(),
            "citations": citations, "queries": queries, "model": model}


def _format(result):
    lines = [result["answer"] or "(no answer)"]
    if result["citations"]:
        lines.append("\nSources:")
        lines += [f"- {u}" for u in result["citations"]]
    return "\n".join(lines)


TOOL_SCHEMA = {
    "name": "web_search",
    "description": "Search the web via Amazon Bedrock and return a grounded answer with source URLs.",
    "inputSchema": {
        "type": "object",
        "properties": {"query": {"type": "string", "description": "the search query"}},
        "required": ["query"],
    },
}


def run_mcp():
    """Minimal MCP stdio server (newline-delimited JSON-RPC 2.0). No mcp/fastmcp dependency."""
    out = sys.stdout

    def send(obj):
        out.write(json.dumps(obj) + "\n")
        out.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        mid = msg.get("id")
        method = msg.get("method")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "bedrock-websearch", "version": "0.1.0"}}})
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [TOOL_SCHEMA]}})
        elif method == "tools/call":
            params = msg.get("params") or {}
            if params.get("name") != "web_search":
                send({"jsonrpc": "2.0", "id": mid,
                      "error": {"code": -32601, "message": "unknown tool"}})
                continue
            query = (params.get("arguments") or {}).get("query", "")
            try:
                text = _format(bedrock_web_search(query))
                is_err = False
            except Exception as e:
                text, is_err = f"web_search failed: {e}", True
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "content": [{"type": "text", "text": text}], "isError": is_err}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid,
                  "error": {"code": -32601, "message": f"method not found: {method}"}})


def main(argv):
    if "--mcp" in argv:
        run_mcp()
        return
    args = [a for a in argv[1:] if not a.startswith("-")]
    if not args:
        print('usage: bedrock_websearch.py "<query>"   |   --mcp', file=sys.stderr)
        sys.exit(2)
    result = bedrock_web_search(" ".join(args))
    if "--json" in argv:
        print(json.dumps(result, ensure_ascii=False))
    else:
        print(_format(result))


if __name__ == "__main__":
    main(sys.argv)
