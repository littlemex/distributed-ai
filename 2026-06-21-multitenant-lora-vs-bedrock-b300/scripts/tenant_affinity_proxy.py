#!/usr/bin/env python3
"""llm-d を立てずに「テナント -> replica 固定」の affinity 効果を測る軽量 proxy (§3)。

8 個の vLLM replica の前段に置き、X-Tenant-ID を consistent-hash して replica を固定する。
ROUTING=affinity なら同テナントは常に同 replica (各 replica が ~125 テナントだけ担当 →
GPU hot-set ヒット率 12.8% に改善)、ROUTING=roundrobin なら全 replica が全テナントを
見る naive baseline (ヒット率 1.6%)。この2モードの TTFT/swap 差が登壇の核 (§1 論点2)。

llm-d の lora-affinity-scorer (active=1.0/capacity=0.8/waiting=0.6/full=0.0) と同じ
「同テナントを同 replica に寄せる」効果を、GIE/Gateway の重いスタック無しで再現する。
これで差が数 ms 以内なら llm-d 本格導入 (Phase 2) は不要、という判定ができる。

環境変数:
  ROUTING       affinity | roundrobin  (default affinity)
  VLLM_REPLICAS カンマ区切りの upstream (default は replica-0..7:8000)
  PROXY_PORT    listen port (default 9000)

X-Tenant-ID ヘッダが無い場合は body の model フィールド (adapter-<i>) を tenant id に流用。

使い方:
  ROUTING=affinity   python tenant_affinity_proxy.py
  ROUTING=roundrobin python tenant_affinity_proxy.py
依存: pip install aiohttp
"""
import hashlib
import json
import os

from aiohttp import ClientSession, web

REPLICAS = os.environ.get(
    "VLLM_REPLICAS",
    ",".join(f"http://vllm-replica-{i}:8000" for i in range(8)),
).split(",")
ROUTING = os.environ.get("ROUTING", "affinity")  # "affinity" | "roundrobin"
PROXY_PORT = int(os.environ.get("PROXY_PORT", "9000"))

_rr = {"i": 0}


def pick(tenant_id: str) -> str:
    if ROUTING == "roundrobin":
        _rr["i"] = (_rr["i"] + 1) % len(REPLICAS)
        return REPLICAS[_rr["i"]]
    # consistent-hash: 同テナント -> 常に同 replica
    h = int(hashlib.md5(tenant_id.encode()).hexdigest(), 16)
    return REPLICAS[h % len(REPLICAS)]


async def handle(req: web.Request):
    body = await req.read()
    tenant = req.headers.get("X-Tenant-ID")
    if not tenant and body:
        try:
            tenant = json.loads(body).get("model", "anon")
        except Exception:
            tenant = "anon"
    upstream = pick(tenant or "anon") + req.path
    # [重要] streaming を壊さないため StreamResponse でチャンクをそのまま透過する。
    # await r.read() で全部読んでから返すと TTFT 計測が崩れる (全チャンクが同時到着扱い)。
    s = ClientSession()
    r = await s.request(req.method, upstream, data=body,
                        headers={"Content-Type": "application/json"})
    resp = web.StreamResponse(status=r.status,
                              headers={"Content-Type": r.headers.get("Content-Type", "application/json")})
    await resp.prepare(req)
    try:
        async for chunk in r.content.iter_any():
            await resp.write(chunk)
    finally:
        r.release()
        await s.close()
    await resp.write_eof()
    return resp


app = web.Application()
app.router.add_route("*", "/{tail:.*}", handle)

if __name__ == "__main__":
    print(f"[INFO] routing={ROUTING}  replicas={len(REPLICAS)}  port={PROXY_PORT}")
    web.run_app(app, port=PROXY_PORT)
