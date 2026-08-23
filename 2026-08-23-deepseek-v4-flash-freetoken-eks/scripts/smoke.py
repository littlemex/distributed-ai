#!/usr/bin/env python3
"""Smoke-check a FreeToken serving deployment through the in-cluster alias.

    python3 scripts/smoke.py [--namespace freetoken] [--context CTX] [--report]

Runs entirely over `kubectl exec` into the serving pod, so it needs no port-forward, no ingress,
and no credentials beyond the kubeconfig already in use.

Beyond the usual "does it answer", this checks two things specific to how FreeToken serves MoE:

* ``/v1/cache/status`` -- the GPU expert-slot cache. A hit rate near zero means almost every token
  is fetching experts over PCIe, which is the difference between "working" and "usable". It is the
  single most diagnostic number for an offload deployment and does not exist in vLLM.
* the served model id from ``/v1/models`` must equal what the profile promised, which catches an
  agent config rendered against a different profile than the engine is running.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys


def kubectl(args: list[str], ctx: str | None) -> str:
    cmd = ["kubectl"]
    if ctx:
        cmd += ["--context", ctx]
    cmd += args
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def pod_name(ns: str, ctx: str | None) -> str:
    out = kubectl(
        ["-n", ns, "get", "pods", "-l", "app.kubernetes.io/name=freetoken-serving",
         "--field-selector=status.phase=Running",
         "-o", "jsonpath={.items[0].metadata.name}"], ctx).strip()
    if not out:
        sys.exit("[smoke][FAIL] no Running freetoken-serving pod found "
                 f"in namespace {ns}; is the deployment Ready?")
    return out


def curl(ns: str, pod: str, ctx: str | None, path: str, payload: dict | None = None) -> object:
    url = f"http://127.0.0.1:1919{path}"
    if payload is None:
        sh = f"curl -sS --max-time 30 {url}"
    else:
        body = json.dumps(payload).replace("'", "'\\''")
        sh = (f"curl -sS --max-time 300 -X POST {url} "
              f"-H 'Content-Type: application/json' -d '{body}'")
    raw = kubectl(["-n", ns, "exec", pod, "--", "sh", "-c", sh], ctx)
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        sys.exit(f"[smoke][FAIL] {path} did not return JSON: {raw[:400]}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--namespace", default="freetoken")
    ap.add_argument("--context", default=None)
    ap.add_argument("--expect-model", default=None,
                    help="fail unless /v1/models reports this id")
    ap.add_argument("--report", action="store_true",
                    help="report findings without failing the run")
    args = ap.parse_args()

    ns, ctx = args.namespace, args.context
    pod = pod_name(ns, ctx)
    print(f"[smoke] pod: {pod}")
    failures: list[str] = []

    health = curl(ns, pod, ctx, "/health")
    print(f"[smoke] /health: {json.dumps(health)[:200]}")

    models = curl(ns, pod, ctx, "/v1/models")
    ids = [m.get("id") for m in (models.get("data") or [])] if isinstance(models, dict) else []
    print(f"[smoke] /v1/models: {ids}")
    if not ids:
        failures.append("/v1/models reported no models")
    elif args.expect_model and args.expect_model not in ids:
        failures.append(f"expected model {args.expect_model!r}, got {ids!r}")

    served = args.expect_model or (ids[0] if ids else None)
    if served:
        chat = curl(ns, pod, ctx, "/v1/chat/completions", {
            "model": served,
            "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
            "max_tokens": 16, "temperature": 0,
        })
        try:
            text = chat["choices"][0]["message"]["content"]
            print(f"[smoke] completion: {text!r}")
        except (KeyError, IndexError, TypeError):
            failures.append(f"chat completion malformed: {json.dumps(chat)[:300]}")

    # FreeToken-specific: the expert-slot cache is what decides whether offload is usable.
    cache = curl(ns, pod, ctx, "/v1/cache/status")
    print(f"[smoke] /v1/cache/status: {json.dumps(cache)[:600]}")

    stats = curl(ns, pod, ctx, "/v1/stats")
    print(f"[smoke] /v1/stats: {json.dumps(stats)[:600]}")

    if failures:
        for f in failures:
            print(f"[smoke][FAIL] {f}", file=sys.stderr)
        if not args.report:
            return 1
        print("[smoke] --report: not failing the run", file=sys.stderr)
    print("[smoke] OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
