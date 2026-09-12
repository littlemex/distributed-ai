#!/usr/bin/env python3
"""stratoclave 課金ゲートウェイの同時実行スイープ計測。

concurrency を段階的に上げて achieved throughput / レイテンシ分布 / エラー内訳を取り、
飽和点を見つける。2つのターゲットを同一コード・同一メトリクスで測れる:

  --target gateway  : stratoclave 経由 (POST /v1/chat/completions, Bearer)
  --target direct   : ゲートウェイを経由しない直接呼び出し
      --direct-transport mantle   : bedrock-mantle の OpenAI 互換面に直接 POST
                                     (aws_bedrock_token_generator でトークンを自前で発行。
                                      ゲートウェイの _mantle_transport.py と同じ経路)
      --direct-transport converse : boto3 bedrock-runtime converse を直接呼ぶ
                                     (Converse 系モデル用。sync なのでスレッドプールで束ねる)

車輪の再発明を避けるため、aiohttp + asyncio.Semaphore による並行化は
~/works/data-science/investigations/multitenant-serving-b300/scripts/concurrency_sweep.py
の設計を再利用している。相違点は: (a) 非ストリーミングも計測対象にした、
(b) ゲートウェイのエラー応答 (402 credit_exhausted の reason 等) を分類する、
(c) direct 比較 (mantle 直叩き / Converse 直叩き) を同一ツールに統合した点。

出力 JSON はステージ毎に追記保存するので、途中で失敗しても部分結果が残る。
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta

import aiohttp


# ---------------------------------------------------------------------------
# 共通ユーティリティ
# ---------------------------------------------------------------------------

def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    i = min(len(sorted_vals) - 1, int(len(sorted_vals) * p))
    return sorted_vals[i]


def classify_error(status, body_text):
    """HTTP status + response body から分類ラベルを作る。
    ゲートウェイの 402 (credit_exhausted) は reason で判別する
    (backend/mvp/_pipeline.py:_err_402: detail={"type":"credit_exhausted","reason":...}).
    400/403/502 は detail.error.{type,code} を見る
    (backend/mvp/chat_completions.py の HTTPException 群、_mantle_status())。
    """
    if status is None:
        return "client_error:no_response"
    try:
        body = json.loads(body_text) if body_text else {}
    except Exception:
        return f"http_{status}:unparseable_body"
    detail = body.get("detail") if isinstance(body, dict) else None
    if isinstance(detail, dict):
        if detail.get("type") == "credit_exhausted":
            return f"http_{status}:credit_exhausted:{detail.get('reason')}"
        if detail.get("type") == "forbidden":
            return f"http_{status}:forbidden:{detail.get('reason')}"
        if detail.get("type") == "invalid_request":
            return f"http_{status}:invalid_request:{detail.get('reason')}"
        err = detail.get("error")
        if isinstance(err, dict):
            return f"http_{status}:{err.get('type')}:{err.get('code')}"
    return f"http_{status}:unknown"


# ---------------------------------------------------------------------------
# gateway / direct-mantle: aiohttp 経由 (どちらも OpenAI 互換 JSON over HTTPS)
# ---------------------------------------------------------------------------

async def one_http_request(session, sem, url, headers_fn, model, prompt, max_tokens, stream, timeout,
                            max_tokens_field="max_tokens"):
    payload = {"model": model, "messages": [{"role": "user", "content": prompt}],
               max_tokens_field: max_tokens, "stream": stream}
    if stream:
        payload["stream_options"] = {"include_usage": True}
    body = json.dumps(payload).encode()
    headers = headers_fn()
    async with sem:
        t0 = time.perf_counter()
        ttft = None
        status = None
        err_label = None
        out_tok = None
        try:
            async with session.post(url, data=body, headers=headers,
                                     timeout=aiohttp.ClientTimeout(total=timeout)) as resp:
                status = resp.status
                if status >= 400:
                    text = await resp.text()
                    err_label = classify_error(status, text)
                elif stream:
                    async for raw in resp.content:
                        line = raw.decode(errors="replace").strip()
                        if not line.startswith("data:"):
                            continue
                        data = line[5:].strip()
                        if data in ("", "[DONE]"):
                            continue
                        if ttft is None:
                            ttft = (time.perf_counter() - t0) * 1000
                else:
                    data = await resp.json()
                    usage = data.get("usage") or {}
                    out_tok = usage.get("completion_tokens")
        except asyncio.TimeoutError:
            err_label = "client_error:TimeoutError"
        except Exception as e:  # noqa: BLE001 — record and move on, never crash the stage
            err_label = f"client_error:{type(e).__name__}"
        total_ms = (time.perf_counter() - t0) * 1000
        return {"status": status, "err": err_label, "total_ms": total_ms,
                "ttft_ms": ttft, "out_tok": out_tok}


# ---------------------------------------------------------------------------
# direct-converse: boto3 bedrock-runtime (sync) をスレッドプールで束ねる
# ---------------------------------------------------------------------------

def one_converse_request(client, model_id, prompt, max_tokens):
    t0 = time.perf_counter()
    status = 200
    err_label = None
    out_tok = None
    try:
        resp = client.converse(
            modelId=model_id,
            messages=[{"role": "user", "content": [{"text": prompt}]}],
            inferenceConfig={"maxTokens": max_tokens},
        )
        usage = resp.get("usage", {})
        out_tok = usage.get("outputTokens")
    except Exception as e:  # noqa: BLE001
        status = None
        err_label = f"client_error:{type(e).__name__}:{str(e)[:150]}"
    total_ms = (time.perf_counter() - t0) * 1000
    return {"status": status, "err": err_label, "total_ms": total_ms,
            "ttft_ms": None, "out_tok": out_tok}


# ---------------------------------------------------------------------------
# ステージ実行 (1つの concurrency 値)
# ---------------------------------------------------------------------------

async def run_stage_http(args, url, headers_fn, model, max_tokens_field, concurrency, n_requests):
    sem = asyncio.Semaphore(concurrency)
    conn = aiohttp.TCPConnector(limit=concurrency + 10, limit_per_host=concurrency + 10)
    t0 = time.perf_counter()
    async with aiohttp.ClientSession(connector=conn) as session:
        tasks = [one_http_request(session, sem, url, headers_fn, model, args.prompt,
                                   args.max_tokens, args.stream, args.timeout, max_tokens_field)
                 for _ in range(n_requests)]
        results = await asyncio.gather(*tasks)
    dur = time.perf_counter() - t0
    return results, dur


async def run_rate_http(args, url, headers_fn, model, max_tokens_field, rate, duration_s):
    """オープンループ計測: 一定レートで送り続け、レイテンシと失敗率を見る。

    クローズドループ (同時実行を固定) は「一気に投げて全部さばけるまでの時間」を
    測るので、ドレイン時間が支配して「どちらが律速か」が見えにくい。
    「ゲートウェイが upstream の同時実行を律速しない」という要件は、
    **同じ提供レートに対してレイテンシと失敗率が upstream 直叩きと同等**、
    という形でしか確かめられない。到着はレートを守り、遅延しても待たない
    (in-flight は必要なだけ増える) ので、律速している側は latency か error に出る。
    """
    conn = aiohttp.TCPConnector(limit=0, limit_per_host=0)
    unbounded = asyncio.Semaphore(10**6)
    interval = 1.0 / rate
    results: list = []
    t0 = time.perf_counter()
    async with aiohttp.ClientSession(connector=conn) as session:
        tasks = []
        sent = 0
        while True:
            now = time.perf_counter() - t0
            if now >= duration_s:
                break
            # 到着時刻を守る。処理が遅れても送信は遅らせない (open loop)。
            target = sent * interval
            if target > now:
                await asyncio.sleep(target - now)
            tasks.append(asyncio.create_task(
                one_http_request(session, unbounded, url, headers_fn, model, args.prompt,
                                 args.max_tokens, args.stream, args.timeout, max_tokens_field)))
            sent += 1
        results = await asyncio.gather(*tasks)
    dur = time.perf_counter() - t0
    return results, dur


def run_stage_converse(args, concurrency, n_requests):
    import boto3
    from botocore.config import Config

    client = boto3.client(
        "bedrock-runtime", region_name=args.direct_region,
        config=Config(max_pool_connections=concurrency + 10,
                       retries={"max_attempts": 0}),  # リトライ無効: 生の天井を見る
    )
    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futs = [pool.submit(one_converse_request, client, args.direct_bedrock_model_id,
                             args.prompt, args.max_tokens) for _ in range(n_requests)]
        results = [f.result() for f in futs]
    dur = time.perf_counter() - t0
    return results, dur


def summarize(results, dur, concurrency, n_requests):
    ok = [r for r in results if r["err"] is None and r["status"] and r["status"] < 400]
    err = [r for r in results if r not in ok]
    status_counts = {}
    err_counts = {}
    for r in results:
        s = r["status"]
        status_counts[str(s)] = status_counts.get(str(s), 0) + 1
        if r["err"]:
            err_counts[r["err"]] = err_counts.get(r["err"], 0) + 1
    lat = sorted(r["total_ms"] for r in ok)
    ttfts = sorted(r["ttft_ms"] for r in ok if r.get("ttft_ms") is not None)
    return {
        "concurrency": concurrency, "n_requests": n_requests, "duration_s": round(dur, 3),
        "n_ok": len(ok), "n_error": len(err),
        "throughput_ok_req_s": round(len(ok) / dur, 2) if dur else 0,
        "attempted_req_s": round(n_requests / dur, 2) if dur else 0,
        "lat_p50_ms": round(pct(lat, 0.50)) if lat else None,
        "lat_p95_ms": round(pct(lat, 0.95)) if lat else None,
        "lat_max_ms": round(max(lat)) if lat else None,
        "ttft_p50_ms": round(pct(ttfts, 0.50)) if ttfts else None,
        "ttft_p95_ms": round(pct(ttfts, 0.95)) if ttfts else None,
        "status_counts": status_counts,
        "err_counts": err_counts,
    }


async def main_async(args):
    dump_path = args.out

    def dump(stages):
        if dump_path:
            os.makedirs(os.path.dirname(dump_path) or ".", exist_ok=True)
            with open(dump_path, "w") as f:
                json.dump({"config": vars(args), "stages": stages}, f, indent=2, default=str)

    headers_fn = None
    url = None
    model = args.model
    max_tokens_field = "max_tokens"
    if args.target == "gateway":
        key = open(os.path.expanduser(args.api_key_file)).read().strip()
        if not args.base_url:
            raise SystemExit(
                "--base-url (or GATEWAY_BASE_URL) is required for --target gateway"
            )
        url = args.base_url.rstrip("/") + "/v1/chat/completions"
        headers_fn = lambda: {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    elif args.target == "direct" and args.direct_transport == "mantle":
        from aws_bedrock_token_generator import provide_token
        url = f"https://bedrock-mantle.{args.direct_region}.api.aws/openai/v1/chat/completions"
        model = args.direct_bedrock_model_id
        # mantle は "max_tokens" を受け付けず "max_completion_tokens" が必須
        # (実測: unsupported_parameter エラー。ゲートウェイの
        # chat_completions.py:_mantle_chat_completion がまさにこの書き換えをしている)。
        max_tokens_field = "max_completion_tokens"
        _tok_cache = {"tok": None, "minted": 0.0}

        def headers_fn():
            # 15分TTLトークンを再利用し、期限が近ければ再発行 (ゲートウェイの
            # _mantle_transport.mint_bearer_token と同じ TTL=900s)。
            if _tok_cache["tok"] is None or time.time() - _tok_cache["minted"] > 800:
                _tok_cache["tok"] = provide_token(region=args.direct_region, expiry=timedelta(seconds=900))
                _tok_cache["minted"] = time.time()
            return {"Authorization": f"Bearer {_tok_cache['tok']}", "Content-Type": "application/json"}

    print(f"# target={args.target} model={model or args.direct_bedrock_model_id} "
          f"stream={args.stream} max_tokens={args.max_tokens}")
    if args.rate:
        print("rate | n | dur_s | ok | err | ok_req/s | lat_p50/p95/max_ms | status | err_types")
    else:
        print("conc | n | dur_s | ok | err | ok_req/s | attempted_req/s | "
              "lat_p50/p95/max_ms | ttft_p50_ms | status | err_types")

    stages = []

    if args.rate:
        # オープンループ。「ゲートウェイが upstream を律速しない」は、同じ提供レートで
        # 両者のレイテンシと失敗率を比べる形でしか確かめられない。
        print("mode=rate (open loop)")
        for r in args.rate:
            try:
                results, dur = await run_rate_http(
                    args, url, headers_fn, model, max_tokens_field, r, args.rate_duration)
            except Exception as e:
                print(f"{r:6} | STAGE FAILED: {type(e).__name__}: {str(e)[:150]}")
                dump(stages)
                continue
            st = summarize(results, dur, r, len(results))
            st["offered_rate"] = r
            stages.append(st)
            et = ",".join(f"{k}:{v}" for k, v in st["err_counts"].items()) or "-"
            sc = ",".join(f"{k}:{v}" for k, v in st["status_counts"].items())
            print(f"{r:6} | {st['n_requests']:5} | {st['duration_s']:6} | "
                  f"{st['n_ok']:5} | {st['n_error']:3} | {st['throughput_ok_req_s']:7} | "
                  f"{st['lat_p50_ms']}/{st['lat_p95_ms']}/{st['lat_max_ms']} | {sc} | {et}")
            dump(stages)
            if args.stage_gap_s:
                await asyncio.sleep(args.stage_gap_s)
        dump(stages)
        return

    for c in args.concurrency:
        n = min(args.max_requests_per_stage, max(args.min_requests_per_stage, c * args.requests_multiplier))
        try:
            if args.target == "direct" and args.direct_transport == "converse":
                results, dur = await asyncio.get_event_loop().run_in_executor(
                    None, run_stage_converse, args, c, n)
            else:
                results, dur = await run_stage_http(args, url, headers_fn, model, max_tokens_field, c, n)
        except Exception as e:
            print(f"{c:4} | STAGE FAILED: {type(e).__name__}: {str(e)[:150]}")
            dump(stages)
            continue
        st = summarize(results, dur, c, n)
        stages.append(st)
        et = ",".join(f"{k}:{v}" for k, v in st["err_counts"].items()) or "-"
        sc = ",".join(f"{k}:{v}" for k, v in st["status_counts"].items())
        print(f"{st['concurrency']:4} | {st['n_requests']:4} | {st['duration_s']:6} | "
              f"{st['n_ok']:3} | {st['n_error']:3} | {st['throughput_ok_req_s']:7} | "
              f"{st['attempted_req_s']:7} | {st['lat_p50_ms']}/{st['lat_p95_ms']}/{st['lat_max_ms']} | "
              f"{st['ttft_p50_ms']} | {sc} | {et}")
        dump(stages)
        if args.stage_gap_s:
            await asyncio.sleep(args.stage_gap_s)

    dump(stages)
    if dump_path:
        print(f"[OK] wrote {dump_path}")


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--target", choices=["gateway", "direct"], required=True)
    p.add_argument("--base-url", default=os.environ.get("GATEWAY_BASE_URL"),
                   help="ゲートウェイの base URL。GATEWAY_BASE_URL からも読む "
                        "(既定値を持たないのは、公開リポジトリに特定環境の "
                        "ホスト名を焼き込まないため)")
    p.add_argument("--api-key-file", default=os.environ.get("GATEWAY_API_KEY_FILE", "~/tmp/mom-bench/.sclv-key"))
    p.add_argument("--model", default="gemma-4", help="gateway 経由の client-facing model alias")
    p.add_argument("--direct-transport", choices=["mantle", "converse"], default="mantle")
    p.add_argument("--direct-bedrock-model-id", default="google.gemma-4-31b")
    p.add_argument("--direct-region", default="us-east-2")
    p.add_argument("--concurrency", type=int, nargs="+", default=[1, 2, 4, 8, 16, 32, 64])
    p.add_argument("--rate", type=float, nargs="+", default=None,
                   help="オープンループ計測: 指定レート (req/s) で --rate-duration 秒送る。"
                        "--concurrency の代わりに使う")
    p.add_argument("--rate-duration", type=float, default=30.0)
    p.add_argument("--requests-multiplier", type=int, default=3,
                    help="ステージあたりのリクエスト数 = concurrency * multiplier (min/max でクランプ)")
    p.add_argument("--min-requests-per-stage", type=int, default=8)
    p.add_argument("--max-requests-per-stage", type=int, default=60)
    p.add_argument("--max-tokens", type=int, default=32)
    p.add_argument("--stream", action="store_true")
    p.add_argument("--prompt", default="Reply with a single short sentence about the weather.")
    p.add_argument("--timeout", type=float, default=60)
    p.add_argument("--stage-gap-s", type=float, default=1.0, help="ステージ間の休止 (DynamoDB ホールド/TTLの影響を切り離す)")
    p.add_argument("--out", default=None)
    return p.parse_args()


if __name__ == "__main__":
    asyncio.run(main_async(parse_args()))
