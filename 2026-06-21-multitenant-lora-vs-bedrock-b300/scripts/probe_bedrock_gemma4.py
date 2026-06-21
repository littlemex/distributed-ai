#!/usr/bin/env python3
"""Bedrock Gemma 4 (bedrock-mantle) の疎通・認証・レイテンシ・課金を実機検証する単発プローブ。

RUNLOG.md の実測 (2026-06-21) を再現するスクリプト。openai SDK 不要 (botocore SigV4 +
urllib のみ) で動く。認証は SigV4 (service="bedrock") — Bearer token 不要。
ストリーミングで TTFT/TPOT、usage で prompt/cached/completion トークンを取得する。

確定事実:
  - Gemma 4 は bedrock-mantle 専用、SigV4 で叩ける (Bearer 不要)。
  - prompt_tokens_details.cached_tokens は常に 0 (Gemma に prompt caching なし = F1 の実証)。

使い方:
  python probe_bedrock_gemma4.py                 # 31B/E2B x system-prompt sweep
  python probe_bedrock_gemma4.py --models google.gemma-4-31b
"""
import argparse
import json
import time
import urllib.request

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

REGION = "us-west-2"
URL = f"https://bedrock-mantle.{REGION}.api.aws/openai/v1/chat/completions"
WORD = "policy compliance access control deployment monitoring "
# 語数で system prompt サイズを近似 (1 token ~= 0.75 words)
SIZES = {
    "none": None,
    "short(~128)": "Tenant config: " + WORD * 18,
    "medium(~512)": "Tenant config: " + WORD * 70,
    "long(~2048)": "Tenant config: " + WORD * 280,
}


def call(creds, model, sys_prompt, user, max_tokens=64):
    msgs = ([{"role": "system", "content": sys_prompt}] if sys_prompt else []) + \
           [{"role": "user", "content": user}]
    body = json.dumps({"model": model, "messages": msgs, "max_tokens": max_tokens,
                       "stream": True, "stream_options": {"include_usage": True}})
    req = AWSRequest(method="POST", url=URL, data=body,
                     headers={"Content-Type": "application/json"})
    SigV4Auth(creds, "bedrock", REGION).add_auth(req)  # service="bedrock" で 200
    t0 = time.perf_counter()
    ttft = None
    usage = None
    ntok = 0
    r = urllib.request.urlopen(
        urllib.request.Request(URL, data=body.encode(), headers=dict(req.headers),
                               method="POST"), timeout=60)
    for raw in r:
        line = raw.decode().strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            break
        ev = json.loads(data)
        if ev.get("choices") and ev["choices"][0].get("delta", {}).get("content"):
            if ttft is None:
                ttft = (time.perf_counter() - t0) * 1000
            ntok += 1
        if ev.get("usage"):
            usage = ev["usage"]
    tot = (time.perf_counter() - t0) * 1000
    tpot = (tot - ttft) / max(ntok - 1, 1) if ttft else None
    return ttft, tot, tpot, usage


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--models", nargs="*",
                   default=["google.gemma-4-31b", "google.gemma-4-e2b"])
    p.add_argument("--max-tokens", type=int, default=64)
    args = p.parse_args()

    creds = boto3.Session().get_credentials().get_frozen_credentials()
    hdr = ("model            | sys_size     | TTFT ms | total ms | TPOT ms | "
           "prompt_tok | cached_tok | out_tok")
    print(hdr)
    for model in args.models:
        for label, sp in SIZES.items():
            try:
                ttft, tot, tpot, u = call(creds, model, sp,
                                          "Summarize your configuration in one sentence.",
                                          args.max_tokens)
                print(f"{model:16} | {label:12} | {ttft:7.0f} | {tot:8.0f} | "
                      f"{tpot:7.1f} | {u['prompt_tokens']:10} | "
                      f"{u['prompt_tokens_details']['cached_tokens']:10} | "
                      f"{u['completion_tokens']}")
            except Exception as e:
                print(f"{model:16} | {label:12} | ERR {type(e).__name__}: {str(e)[:80]}")
            time.sleep(0.5)
