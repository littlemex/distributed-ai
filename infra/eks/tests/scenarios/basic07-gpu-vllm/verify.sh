#!/usr/bin/env bash
# Basic07 — verify the OpenAI-compatible API: model list and a text completion, from inside the
# serving pod. Model-agnostic (asserts non-empty results).
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
