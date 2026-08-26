#!/usr/bin/env python3
"""Smoke check for the Qwen3.8-27B serving endpoint, run via kubectl exec (no port-forward).

Checks, against the active serving pod's localhost:8000:
  (a) /v1/models returns the expected served-model-name
  (b) a short chat returns non-empty content
  (c) a tool-calling request returns a tool_call
  (d) the startup log shows the speculative-decode engine active (MTP for vLLM, DFLASH for sglang)

Modes:
  --gate    (default) all four required; exit 1 if any fails. Used before flipping the alias.
  --report  (a)(b)(d) required; (c) recorded only. Prints `SMOKE(c)=PASS|FAIL`, exit 0 if a/b/d pass.
            Used for a standalone opt-in deploy that does not touch the alias.

The promotion criterion "tool-calling works" is exactly the (c) line this prints; there is no
separate definition.
"""
import argparse, json, subprocess, sys

MODEL = "Qwen/Qwen3.8-27B"

def sh(args):
    return subprocess.run(args, capture_output=True, text=True)

def serving_pod(ctx, ns, engine):
    sel = "app.kubernetes.io/name=vllm-serving" if engine == "vllm" else "app=sglang-qwen"
    r = sh(["kubectl", "--context", ctx, "-n", ns, "get", "pod", "-l", sel,
            "--field-selector=status.phase=Running", "-o",
            "jsonpath={.items[0].metadata.name}"])
    return r.stdout.strip()

def in_pod(ctx, ns, pod, py):
    return sh(["kubectl", "--context", ctx, "-n", ns, "exec", pod, "--", "python3", "-c", py])

CHECK_PY = r'''
import urllib.request, json
B="http://localhost:8000"
def get(p):
    return json.load(urllib.request.urlopen(B+p, timeout=30))
def post(body):
    req=urllib.request.Request(B+"/v1/chat/completions", data=json.dumps(body).encode(),
        headers={"Content-Type":"application/json"})
    return json.load(urllib.request.urlopen(req, timeout=120))
out={}
try:
    m=get("/v1/models"); out["a"]=any(d.get("id")=="%(model)s" for d in m.get("data",[]))
except Exception as e: out["a"]=False
try:
    r=post({"model":"%(model)s","messages":[{"role":"user","content":"Say OK."}],"max_tokens":8,"temperature":0})
    out["b"]=bool(r["choices"][0]["message"].get("content"))
except Exception as e: out["b"]=False
try:
    r=post({"model":"%(model)s","messages":[{"role":"user","content":"Weather in Tokyo? use the tool"}],
        "tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
        "tool_choice":"auto","max_tokens":64,"temperature":0})
    out["c"]=bool(r["choices"][0]["message"].get("tool_calls"))
except Exception as e: out["c"]=False
print(json.dumps(out))
''' % {"model": MODEL}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--context", required=True)
    ap.add_argument("--namespace", required=True)
    ap.add_argument("--engine", choices=["vllm", "sglang"], default="vllm")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--gate", action="store_true")
    g.add_argument("--report", action="store_true")
    a = ap.parse_args()
    report = a.report and not a.gate

    pod = serving_pod(a.context, a.namespace, a.engine)
    if not pod:
        print("[smoke][FAIL] no running serving pod"); sys.exit(1)

    r = in_pod(a.context, a.namespace, pod, CHECK_PY)
    try:
        res = json.loads(r.stdout.strip().splitlines()[-1])
    except Exception:
        print("[smoke][FAIL] could not run checks in pod:\n" + r.stderr[-400:]); sys.exit(1)

    # (d) speculative decoding active. "Detected MTP"/"DFLASH" only appear once at startup and can
    # scroll out of a bounded tail on a long-running pod, so check the recurring per-step metrics
    # line instead ("SpecDecoding metrics: ..."), falling back to the one-time startup message for
    # a pod that has not served a request yet.
    logs = sh(["kubectl", "--context", a.context, "-n", a.namespace, "logs", pod, "--tail=2000"])
    needle = "Detected MTP" if a.engine == "vllm" else "DFLASH"
    res["d"] = "specdecoding metrics" in logs.stdout.lower() or needle.lower() in logs.stdout.lower()

    for k in ("a", "b", "c", "d"):
        print(f"  ({k}) {'PASS' if res.get(k) else 'FAIL'}")
    print(f"SMOKE(c)={'PASS' if res.get('c') else 'FAIL'}")

    required = ("a", "b", "d") if report else ("a", "b", "c", "d")
    ok = all(res.get(k) for k in required)
    if report and not res.get("c"):
        print("[smoke] (c) tool-calling FAIL -> not promotable")
    print("[smoke] PASS" if ok else "[smoke] FAIL")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
