#!/usr/bin/env bash
# Basic09 — verify the OpenAI-compatible API: model list, a text completion, and a multimodal
# (image) completion. Runs the requests INSIDE the serving pod (the DLC ships python3), so no
# port-forward/curl/jq is needed on the client. Model-agnostic: asserts non-empty results, not a
# specific model. The image is a tiny embedded data URL so the check is hermetic (no egress to a
# third-party image host) and every request has a timeout so a network black-hole cannot hang the
# suite. (The Basic09 chapter shows a real-image example for readers.)
set -euo pipefail
ns="${NAMESPACE:?set NAMESPACE}"
pod="$(kubectl get pod -n "$ns" -l app=neuron-vllm --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"
[ -n "$pod" ] || { echo "no Running neuron-vllm pod"; exit 1; }

IMG_DATA_URL="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR42mO4oKBAEmIY1TCqYfhqAABLfxAQegypMgAAAABJRU5ErkJggg=="

kubectl exec "$pod" -n "$ns" -- python3 -c '
import json,urllib.request
d=json.load(urllib.request.urlopen("http://localhost:8000/v1/models", timeout=60))
mid=d["data"][0]["id"]; assert mid, d
print("models ok:", mid)
'
kubectl exec "$pod" -n "$ns" -- python3 -c '
import json,urllib.request
mid=json.load(urllib.request.urlopen("http://localhost:8000/v1/models", timeout=60))["data"][0]["id"]
req=urllib.request.Request("http://localhost:8000/v1/chat/completions",
  data=json.dumps({"model":mid,"messages":[{"role":"user","content":"Say hello in one word."}],"max_tokens":16}).encode(),
  headers={"Content-Type":"application/json"})
d=json.load(urllib.request.urlopen(req, timeout=120))
c=d["choices"][0]["message"]["content"].strip(); assert c, d
print("text ok:", repr(c))
'
kubectl exec "$pod" -n "$ns" -- env IMG="$IMG_DATA_URL" python3 -c '
import os,json,urllib.request
mid=json.load(urllib.request.urlopen("http://localhost:8000/v1/models", timeout=60))["data"][0]["id"]
msg=[{"role":"user","content":[
  {"type":"image_url","image_url":{"url":os.environ["IMG"]}},
  {"type":"text","text":"Describe this image in one word."}]}]
req=urllib.request.Request("http://localhost:8000/v1/chat/completions",
  data=json.dumps({"model":mid,"messages":msg,"max_tokens":16}).encode(),
  headers={"Content-Type":"application/json"})
d=json.load(urllib.request.urlopen(req, timeout=120))
c=d["choices"][0]["message"]["content"].strip(); assert c, d
print("image ok:", repr(c), "prompt_tokens=", d["usage"]["prompt_tokens"])
'
