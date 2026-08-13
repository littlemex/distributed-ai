#!/usr/bin/env bash
# Basic09 — verify the OpenAI-compatible API: model list, a text completion, and a multimodal
# (image) completion. Runs the requests INSIDE the serving pod (the DLC ships python3), so no
# port-forward/curl/jq is needed. Model-agnostic: asserts non-empty results, not a specific model.
set -euo pipefail
ns="${NAMESPACE:?set NAMESPACE}"
pod="$(kubectl get pod -n "$ns" -l app=neuron-vllm -o jsonpath='{.items[0].metadata.name}')"
[ -n "$pod" ] || { echo "no neuron-vllm pod"; exit 1; }

kubectl exec "$pod" -n "$ns" -- python3 -c '
import json,urllib.request
d=json.load(urllib.request.urlopen("http://localhost:8000/v1/models"))
mid=d["data"][0]["id"]; assert mid, d
print("models ok:", mid)
'
kubectl exec "$pod" -n "$ns" -- python3 -c '
import json,urllib.request
req=urllib.request.Request("http://localhost:8000/v1/chat/completions",
  data=json.dumps({"model":json.load(urllib.request.urlopen("http://localhost:8000/v1/models"))["data"][0]["id"],
                   "messages":[{"role":"user","content":"Say hello in one word."}],"max_tokens":16}).encode(),
  headers={"Content-Type":"application/json"})
d=json.load(urllib.request.urlopen(req))
c=d["choices"][0]["message"]["content"].strip(); assert c, d
print("text ok:", repr(c))
'
kubectl exec "$pod" -n "$ns" -- python3 -c '
import json,urllib.request
mid=json.load(urllib.request.urlopen("http://localhost:8000/v1/models"))["data"][0]["id"]
msg=[{"role":"user","content":[
  {"type":"image_url","image_url":{"url":"http://images.cocodataset.org/val2017/000000039769.jpg"}},
  {"type":"text","text":"How many animals are in the image? Answer in one word."}]}]
req=urllib.request.Request("http://localhost:8000/v1/chat/completions",
  data=json.dumps({"model":mid,"messages":msg,"max_tokens":16}).encode(),
  headers={"Content-Type":"application/json"})
d=json.load(urllib.request.urlopen(req))
c=d["choices"][0]["message"]["content"].strip(); assert c, d
print("image ok:", repr(c), "prompt_tokens=", d["usage"]["prompt_tokens"])
'
