#!/usr/bin/env python3
"""Smoke check for the serving endpoint, run via kubectl exec (no port-forward).

Checks, against the active serving pod's localhost:8000:
  (a) /v1/models returns the expected served-model-name
  (b) a short chat returns non-empty content
  (c) a tool-calling request returns a tool_call
  (d) the engine's speculative decoding agrees with what the deploy asked for

Modes:
  --gate    (default) all four required; exit 1 if any fails. Used before flipping the alias.
  --report  (a)(b)(d) required; (c) recorded only. Prints `SMOKE(c)=PASS|FAIL`, exit 0 if a/b/d pass.
            Used for a standalone opt-in deploy that does not touch the alias.

The promotion criterion "tool-calling works" is exactly the (c) line this prints; there is no
separate definition.

The served-model-name is an argument, not a constant. It was a constant once, left pointing at the
previous model after the box was swapped, so all three endpoint checks failed against a perfectly
healthy endpoint. `model.env` is the single source of truth and `deploy.sh` passes it in.

(d) checks agreement rather than presence, because the `throughput` tune turns speculative decoding
off on purpose. A check that requires MTP can never pass on that profile, and a gate that always
fails is worse than no gate: it teaches everyone to ignore the gate.
"""
import argparse, json, subprocess, sys


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
'''


def check_py(model: str) -> str:
    return CHECK_PY % {"model": model}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--context", required=True)
    ap.add_argument("--namespace", required=True)
    ap.add_argument("--engine", choices=["vllm", "sglang"], default="vllm")
    ap.add_argument("--model", required=True, help="served-model-name, from model.env")
    ap.add_argument("--expect-speculative", choices=["yes", "no"], default="yes",
                    help="what the deploy's tune asked for; (d) checks the engine agrees")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--gate", action="store_true")
    g.add_argument("--report", action="store_true")
    a = ap.parse_args()
    report = a.report and not a.gate

    pod = serving_pod(a.context, a.namespace, a.engine)
    if not pod:
        print("[smoke][FAIL] no running serving pod"); sys.exit(1)

    r = in_pod(a.context, a.namespace, pod, check_py(a.model))
    try:
        res = json.loads(r.stdout.strip().splitlines()[-1])
    except Exception:
        print("[smoke][FAIL] could not run checks in pod:\n" + r.stderr[-400:]); sys.exit(1)

    # (d) "Detected MTP"/"DFLASH" appear once at startup and can scroll out of a bounded tail on a
    # long-running pod, so the recurring per-step metrics line is checked too.
    logs = sh(["kubectl", "--context", a.context, "-n", a.namespace, "logs", pod, "--tail=2000"])
    needle = "Detected MTP" if a.engine == "vllm" else "DFLASH"
    active = ("specdecoding metrics" in logs.stdout.lower()
              or needle.lower() in logs.stdout.lower())
    res["d"] = active == (a.expect_speculative == "yes")
    if not res["d"]:
        print(f"  (d) engine speculative={active}, deploy asked for "
              f"{a.expect_speculative == 'yes'}")

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
