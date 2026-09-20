#!/usr/bin/env bash
# Basic07 — verify the OpenAI-compatible API: model list, a text completion, and a request carrying
# tool definitions, from inside the serving pod. Model-agnostic (asserts non-empty results).
#
# The third check covers gpuServingVllm.extraArgs as far as the engine: a request with `tools` is
# rejected with 400 unless the engine was started with --enable-auto-tool-choice and a
# --tool-call-parser, so it passes only when the flags in this scenario's values reached the
# container. The render test asserts they appear in the manifest; this asserts the engine got them.
#
# It does NOT assert that the model emits a tool call -- whether a small model chooses to call one is
# not deterministic, so a text answer passes too. What is being verified is the flag's arrival.
set -euo pipefail
ns="${NAMESPACE:?set NAMESPACE}"
pod="$(kubectl get pod -n "$ns" -l app=gpu-vllm -o jsonpath='{.items[0].metadata.name}')"
[ -n "$pod" ] || { echo "no gpu-vllm pod"; exit 1; }
kubectl exec "$pod" -n "$ns" -- python3 -c '
import json,urllib.request
d=json.load(urllib.request.urlopen("http://localhost:8000/v1/models"))
assert d["data"][0]["id"], d; print("models ok:", d["data"][0]["id"])
'
kubectl exec "$pod" -n "$ns" -- python3 -c '
import json,urllib.request
mid=json.load(urllib.request.urlopen("http://localhost:8000/v1/models"))["data"][0]["id"]
req=urllib.request.Request("http://localhost:8000/v1/chat/completions",
  data=json.dumps({"model":mid,"messages":[{"role":"user","content":"Say hello in one word."}],"max_tokens":16}).encode(),
  headers={"Content-Type":"application/json"})
d=json.load(urllib.request.urlopen(req))
c=d["choices"][0]["message"]["content"].strip(); assert c, d; print("text ok:", repr(c))
'
kubectl exec "$pod" -n "$ns" -- python3 -c '
import json,urllib.error,urllib.request
mid=json.load(urllib.request.urlopen("http://localhost:8000/v1/models"))["data"][0]["id"]
body={"model":mid,
      "messages":[{"role":"user","content":"What is in the file notes.txt?"}],
      "tools":[{"type":"function","function":{"name":"read_file","description":"read a file",
                "parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}],
      "max_tokens":32}
req=urllib.request.Request("http://localhost:8000/v1/chat/completions",
  data=json.dumps(body).encode(), headers={"Content-Type":"application/json"})
try:
    d=json.load(urllib.request.urlopen(req))
except urllib.error.HTTPError as e:
    # The body decides the diagnosis, not the status code. A 400 also comes back from a malformed request, a parser
    # name that does not match the model, or an over-long context, and naming the wrong cause sends the next person to
    # the wrong file.
    msg = e.read()[:300].decode(errors="replace")
    hint = (" -- the engine was started without the tool-choice flags, so gpuServingVllm.extraArgs did not reach the "
            "container") if "tool choice" in msg else ""
    raise SystemExit("a request carrying tools was rejected with %d: %s%s" % (e.code, msg, hint))
m=d["choices"][0]["message"]
assert m.get("content") or m.get("tool_calls"), d
print("tools ok:", "tool_call" if m.get("tool_calls") else "text answer")
'
