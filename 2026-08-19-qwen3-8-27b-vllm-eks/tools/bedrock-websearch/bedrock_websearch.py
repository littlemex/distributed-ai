#!/usr/bin/env python3
"""Bedrock Web Search wrapper — expose Amazon Bedrock's server-side `web_search`
tool as a plain search tool that any agent can call, so a self-hosted model
(e.g. Qwen on vLLM) stays the "brain" while Bedrock does the web search.

Standard-library only: SigV4 signing and credential resolution are hand-rolled so
this runs on a bare python3 (no pip/botocore) — e.g. inside the OpenClaw container.
Credentials, in order: explicit AWS_* env vars, then EKS Pod Identity / ECS container
credentials endpoint (AWS_CONTAINER_CREDENTIALS_FULL_URI + token file), then botocore
if it happens to be installed (local dev convenience).

Entrypoints:
  - CLI : `bedrock_websearch.py "<query>"`   -> prints answer + sources (for openclaw exec).
  - MCP : `bedrock_websearch.py --mcp`        -> stdio JSON-RPC MCP server, tool `web_search`.

Env: BEDROCK_WS_REGION (us-east-1|us-east-2|us-west-2, default us-east-1),
     BEDROCK_WS_MODEL (default openai.gpt-5.6-sol), BEDROCK_WS_EXTERNAL (default true).
"""
import datetime
import hashlib
import hmac
import json
import os
import sys
import urllib.request

DEFAULT_REGION = os.environ.get("BEDROCK_WS_REGION", "us-east-1")
DEFAULT_MODEL = os.environ.get("BEDROCK_WS_MODEL", "openai.gpt-5.6-sol")
EXTERNAL = os.environ.get("BEDROCK_WS_EXTERNAL", "true").lower() in ("1", "true", "yes")
SERVICE = "bedrock"


def _get_credentials():
    """Return (access_key, secret_key, session_token|None)."""
    ak = os.environ.get("AWS_ACCESS_KEY_ID")
    sk = os.environ.get("AWS_SECRET_ACCESS_KEY")
    if ak and sk:
        return ak, sk, os.environ.get("AWS_SESSION_TOKEN")
    # EKS Pod Identity / ECS container credentials endpoint
    uri = os.environ.get("AWS_CONTAINER_CREDENTIALS_FULL_URI")
    rel = os.environ.get("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")
    if rel and not uri:
        uri = "http://169.254.170.2" + rel
    if uri:
        headers = {}
        tok_file = os.environ.get("AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE")
        tok = os.environ.get("AWS_CONTAINER_AUTHORIZATION_TOKEN")
        if tok_file and os.path.exists(tok_file):
            tok = open(tok_file).read().strip()
        if tok:
            headers["Authorization"] = tok
        req = urllib.request.Request(uri, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as r:
            d = json.load(r)
        return d["AccessKeyId"], d["SecretAccessKey"], d.get("Token")
    # last resort: botocore (local dev with profiles/SSO)
    try:
        import botocore.session
        c = botocore.session.get_session().get_credentials()
        if c:
            c = c.get_frozen_credentials()
            return c.access_key, c.secret_key, c.token
    except Exception:
        pass
    raise RuntimeError("no AWS credentials (env / Pod Identity endpoint / botocore) found")


def _sign(method, host, path, body, region, ak, sk, token):
    """Return SigV4 headers for a POST to host+path."""
    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body.encode()).hexdigest()

    headers = {"content-type": "application/json", "host": host,
               "x-amz-date": amzdate, "x-amz-content-sha256": payload_hash}
    if token:
        headers["x-amz-security-token"] = token
    signed_headers = ";".join(sorted(headers))
    canonical_headers = "".join(f"{k}:{headers[k]}\n" for k in sorted(headers))
    canonical_request = "\n".join([method, path, "", canonical_headers, signed_headers, payload_hash])

    scope = f"{datestamp}/{region}/{SERVICE}/aws4_request"
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256", amzdate, scope,
        hashlib.sha256(canonical_request.encode()).hexdigest()])

    def _hmac(key, msg):
        return hmac.new(key, msg.encode(), hashlib.sha256).digest()

    k = _hmac(("AWS4" + sk).encode(), datestamp)
    k = _hmac(k, region)
    k = _hmac(k, SERVICE)
    k = _hmac(k, "aws4_request")
    sig = hmac.new(k, string_to_sign.encode(), hashlib.sha256).hexdigest()
    headers["Authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={sig}")
    return headers


def bedrock_web_search(query, region=None, model=None, external=None):
    """Run one web-search-grounded Responses call. Returns {answer, citations, queries}."""
    region = region or DEFAULT_REGION
    model = model or DEFAULT_MODEL
    ext = EXTERNAL if external is None else external

    ak, sk, token = _get_credentials()
    host = f"bedrock-mantle.{region}.api.aws"
    path = "/openai/v1/responses"
    body = json.dumps({
        "model": model,
        "input": query,
        "tools": [{"type": "web_search", "external_web_access": ext}],
    })
    headers = _sign("POST", host, path, body, region, ak, sk, token)
    req = urllib.request.Request(f"https://{host}{path}", data=body.encode(),
                                 headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=120) as r:
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
    """Minimal MCP stdio server (newline-delimited JSON-RPC 2.0). No dependencies."""
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
                "serverInfo": {"name": "bedrock-websearch", "version": "0.2.0"}}})
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
    print(json.dumps(result, ensure_ascii=False) if "--json" in argv else _format(result))


if __name__ == "__main__":
    main(sys.argv)
