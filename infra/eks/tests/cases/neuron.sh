#!/usr/bin/env bash
# Trainium serving test (vLLM Neuron plugin). Files under cases/ group functions by area; each
# test's layer and suite are declared in registry.sh (the single source). This is the standalone
# 'neuron' suite: it needs a Trainium node (a region-specific Capacity Block) and so is never part
# of baseline/coverage/full — run it with `./run-tests.sh --suite neuron`.

# True when some node advertises the Neuron device resource (a joined trn/inf node). Used to SKIP
# (rc=2) rather than FAIL when the cluster/region has no Trainium capacity.
neuron_node_present() {
  kubectl get nodes \
    -o jsonpath='{range .items[*]}{.status.capacity.aws\.amazon\.com/neuron}{"\n"}{end}' 2>/dev/null \
    | grep -qE '^[1-9]'
}

neuron_serving_pod() {
  kubectl get pod -n "$NAMESPACE" -l app=neuron-qwen3vl \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Hit the in-pod OpenAI server with a python one-liner run INSIDE the serving pod: the DLC ships
# python3, so this needs no curl/jq/port-forward on the client. Echoes the extracted value.
neuron_api() {
  kubectl exec "$1" -n "$NAMESPACE" -- python3 -c "$2" 2>/dev/null
}

test_neuron_vllm_qwen3vl() {
  local pod model text_len img_len
  neuron_node_present || return 2   # SKIP: no Trainium node in this cluster/region

  # Tear the workload down on both exit paths of run_test's subshell: EXIT (errexit failure) and
  # TERM (watchdog process-group SIGTERM on timeout). Namespaced, so the namespace teardown also
  # cleans it, but deleting eagerly frees the single Trainium device.
  # shellcheck disable=SC2064
  trap "kubectl delete -f '$SCRIPT_DIR/manifests/neuron-vllm-plugin.yaml' -n '$NAMESPACE' --wait=false >/dev/null 2>&1 || true" EXIT
  # shellcheck disable=SC2064
  trap "kubectl delete -f '$SCRIPT_DIR/manifests/neuron-vllm-plugin.yaml' -n '$NAMESPACE' --wait=false >/dev/null 2>&1 || true; exit 143" TERM

  apply_manifest neuron-vllm-plugin.yaml

  # First run downloads the model then compiles it to NEFF (many minutes); rollout waits for the
  # readiness probe. The registry timeout (40m) bounds the whole test above this 35m rollout wait.
  kubectl -n "$NAMESPACE" rollout status deploy/neuron-qwen3vl --timeout=35m || return 1
  pod="$(neuron_serving_pod)"
  [ -n "$pod" ] || return 1

  # /v1/models must advertise the served model.
  model="$(neuron_api "$pod" '
import json,urllib.request
d=json.load(urllib.request.urlopen("http://localhost:8000/v1/models"))
print(d["data"][0]["id"])')"
  [ "$model" = "Qwen/Qwen3-VL-4B-Instruct" ] || return 1

  # Text chat completion returns non-empty content.
  text_len="$(neuron_api "$pod" '
import json,urllib.request
req=urllib.request.Request("http://localhost:8000/v1/chat/completions",
  data=json.dumps({"model":"Qwen/Qwen3-VL-4B-Instruct","messages":[{"role":"user","content":"Say hello in one word."}],"max_tokens":16}).encode(),
  headers={"Content-Type":"application/json"})
d=json.load(urllib.request.urlopen(req))
print(len(d["choices"][0]["message"]["content"].strip()))')"
  [ -n "$text_len" ] && [ "$text_len" -gt 0 ] || return 1

  # Multimodal (image) chat completion returns non-empty content — proves the vision path compiled
  # and the image reached the model.
  img_len="$(neuron_api "$pod" '
import json,urllib.request
msg=[{"role":"user","content":[
  {"type":"image_url","image_url":{"url":"http://images.cocodataset.org/val2017/000000039769.jpg"}},
  {"type":"text","text":"How many animals are in the image? Answer in one word."}]}]
req=urllib.request.Request("http://localhost:8000/v1/chat/completions",
  data=json.dumps({"model":"Qwen/Qwen3-VL-4B-Instruct","messages":msg,"max_tokens":16}).encode(),
  headers={"Content-Type":"application/json"})
d=json.load(urllib.request.urlopen(req))
print(len(d["choices"][0]["message"]["content"].strip()))')"
  [ -n "$img_len" ] && [ "$img_len" -gt 0 ] || return 1
}
