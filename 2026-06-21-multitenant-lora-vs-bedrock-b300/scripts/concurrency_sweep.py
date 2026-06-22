#!/usr/bin/env python3
"""OpenAI 互換エンドポイント共通の concurrency sweep ベンチ (TTFT/TPOT/Goodput + 503飽和点)。

Bedrock (bedrock-mantle, SigV4) と 自前 vLLM (Bearer or 無認証) を**同一コード・同一メトリクス・
同一 SLO**で計測するための1本。GPU 側も後で --base-url / --model を差し替えるだけで同じ表に並ぶ。
これがメトリクス定義のズレを原理的に防ぐ (DESIGN.md §9, ユーザ確定方針 2026-06-21)。

メトリクス (各リクエストを streaming で計測):
  TTFT  = request 送信 -> 最初の非空トークン受信 [ms]
  TPOT  = (total_ms - TTFT) / (out_tokens - 1)     [ms/token]
  Goodput = good_requests / wall_clock [req/s]
            good = (TTFT <= slo_ttft_ms) AND (TPOT <= slo_tpot_ms) AND error 無し
  503/error も計上し、achievable goodput の飽和点 (Bedrock throttle) を捕捉する (論点1)。

認証:
  --auth sigv4   : botocore SigV4 (service=bedrock)。Bedrock Gemma 4 用。openai SDK 不要。
  --auth bearer  : Authorization: Bearer $API_KEY。vLLM/その他 OpenAI 互換用。
  --auth none    : 認証なし (ローカル vLLM 用)。

テナント (per-request の system prompt or adapter):
  --dataset <jsonl>  : scripts/gen_bedrock_dataset.py 形式 (conversations[system,human], tenant_id)。
                       Bedrock 用。各リクエストが distinct system prompt を持つ。
  --adapters <N>     : vLLM 用。model フィールドを adapter-0..N-1 から Zipf/uniform で選ぶ。
  どちらも無ければ単一の固定プロンプト。

使い方:
  # Bedrock Gemma 4 31B, distinct system prompt, concurrency 10/50/100/200/400
  python concurrency_sweep.py --base-url https://bedrock-mantle.us-west-2.api.aws/openai/v1 \
     --model google.gemma-4-31b --auth sigv4 --dataset data/bedrock_dataset_medium_1000tenants.jsonl \
     --concurrency 10 50 100 200 400 --requests-per-stage 400 --max-tokens 64 \
     --slo-ttft-ms 2000 --slo-tpot-ms 80 --out results/bedrock-31b-sweep.json

  # 自前 vLLM (GPU が空いたら): 同じツール、base-url/model/auth/adapters を差し替えるだけ
  python concurrency_sweep.py --base-url http://localhost:9000/v1 --model google/gemma-3-27b-it \
     --auth none --adapters 1000 --zipf 1.1 --concurrency 10 50 100 200 400 \
     --requests-per-stage 400 --max-tokens 64 --slo-ttft-ms 2000 --slo-tpot-ms 80 \
     --out results/vllm-27b-sweep.json
"""
import argparse
import asyncio
import json
import os
import time
import urllib.error
import urllib.request

# ---- optional SigV4 (Bedrock) ----
def _sigv4_headers(method, url, body, region="us-west-2", service="bedrock"):
    import boto3
    from botocore.auth import SigV4Auth
    from botocore.awsrequest import AWSRequest
    creds = boto3.Session().get_credentials().get_frozen_credentials()
    req = AWSRequest(method=method, url=url, data=body,
                     headers={"Content-Type": "application/json"})
    SigV4Auth(creds, service, region).add_auth(req)
    return dict(req.headers)


def build_headers(auth, method, url, body, region):
    h = {"Content-Type": "application/json"}
    if auth == "sigv4":
        return _sigv4_headers(method, url, body, region=region)
    if auth == "bearer":
        key = os.environ.get("API_KEY") or os.environ.get("BEDROCK_API_KEY", "")
        h["Authorization"] = f"Bearer {key}"
    return h


# ---- tenant prompt sources ----
def load_dataset(path):
    rows = []
    with open(path) as f:
        for line in f:
            rows.append(json.loads(line))
    return rows


def zipf_indices(n, s, count, seed=0):
    import random
    w = [1.0 / (k ** s) for k in range(1, n + 1)]
    tot = sum(w)
    w = [x / tot for x in w]
    rng = random.Random(seed)
    # cumulative sampling
    cum = []
    acc = 0.0
    for x in w:
        acc += x
        cum.append(acc)
    out = []
    for _ in range(count):
        r = rng.random()
        lo, hi = 0, n - 1
        while lo < hi:
            mid = (lo + hi) // 2
            if cum[mid] < r:
                lo = mid + 1
            else:
                hi = mid
        out.append(lo)
    return out


# ---- single request (TRUE async via aiohttp) ----
# 重要: 以前は asyncio.to_thread + blocking urllib だったが、default ThreadPoolExecutor の
# max_workers=min(32, cpu+4)=14 で頭打ちになり、--concurrency 200/300 を指定しても実効同時実行が
# 14 で頭打ちになる致命的バグがあった (TTFT/goodput が concurrency 不変に見えた原因)。
# aiohttp で真の非同期にし、指定 concurrency 通りに並行させる。
async def one_request(session, sem, url, auth, region, model, sys_prompt, user,
                      max_tokens, timeout, ignore_eos=False):
    msgs = ([{"role": "system", "content": sys_prompt}] if sys_prompt else []) + \
           [{"role": "user", "content": user}]
    payload = {"model": model, "messages": msgs, "max_tokens": max_tokens,
               "stream": True, "stream_options": {"include_usage": True}}
    if ignore_eos:
        payload["ignore_eos"] = True  # 自ホスト: 出力長を固定し TPOT を安定計測
    body = json.dumps(payload)
    headers = build_headers(auth, "POST", url, body, region)  # SigV4 は body 毎に署名
    async with sem:
        t0 = time.perf_counter()
        ttft = None
        usage = None
        ntok = 0
        stream_err = None
        code = None
        try:
            async with session.post(url, data=body.encode(), headers=headers) as resp:
                code = resp.status
                if resp.status >= 400:
                    await resp.read()
                    return {"error": f"HTTP {resp.status}", "code": resp.status,
                            "ttft_ms": None, "tpot_ms": None,
                            "total_ms": (time.perf_counter() - t0) * 1000}
                async for raw in resp.content:
                    line = raw.decode(errors="replace").strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        ev = json.loads(data)
                    except Exception:
                        continue
                    ch = ev.get("choices")
                    if ch and ch[0].get("delta", {}).get("content"):
                        if ttft is None:
                            ttft = (time.perf_counter() - t0) * 1000
                        ntok += 1
                    if ev.get("usage"):
                        usage = ev["usage"]
        except Exception as e:
            # 接続リセット/タイムアウト等 (Bedrock throttle の一形態)。
            # 受信済み ttft/ntok は活かしつつ error 計上。
            stream_err = type(e).__name__
        total = (time.perf_counter() - t0) * 1000
        tpot = (total - ttft) / max(ntok - 1, 1) if ttft and ntok > 1 else None
        out_tok = usage["completion_tokens"] if usage else ntok
        prompt_tok = usage["prompt_tokens"] if usage else None
        return {"error": stream_err, "code": (code if stream_err is None else code),
                "ttft_ms": ttft, "tpot_ms": tpot, "total_ms": total,
                "out_tok": out_tok, "prompt_tok": prompt_tok}


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    i = min(len(sorted_vals) - 1, int(len(sorted_vals) * p))
    return sorted_vals[i]


def _route_url(urls, routing, adapter_idx, req_idx):
    """複数 replica URL への per-request ルーティング (proxy 不要)。
    roundrobin: req_idx で循環 / affinity: adapter id のハッシュで同テナント->同 replica 固定。"""
    if len(urls) == 1:
        return urls[0]
    if routing == "affinity" and adapter_idx is not None:
        return urls[adapter_idx % len(urls)]
    return urls[req_idx % len(urls)]


async def run_stage(args, rows, concurrency, n_requests):
    import aiohttp
    urls = [u.rstrip("/") + "/chat/completions" for u in args.base_url.split(",")]
    sem = asyncio.Semaphore(concurrency)
    user = "Summarize your configuration in one sentence."
    # --input-tokens 指定時は N トークン相当の合成 user prompt (limit 探索用)。
    # 1 token ~= 0.75 words 概算。テナント毎に少し変えるため index を付ける。
    if args.input_tokens:
        nw = int(args.input_tokens * 0.75)
        _filler = ("policy compliance access control deployment monitoring region quota service "
                   "account role permission infrastructure audit governance security ").split()
        user = "Question. " + " ".join(_filler[k % len(_filler)] for k in range(nw))

    # aiohttp connector limit を concurrency 以上にして真の並行を担保。
    timeout = aiohttp.ClientTimeout(total=args.timeout)
    conn = aiohttp.TCPConnector(limit=concurrency + 10, limit_per_host=concurrency + 10)
    t0 = time.perf_counter()
    async with aiohttp.ClientSession(connector=conn, timeout=timeout) as session:
        # build per-request (sys_prompt, model)
        ieos = args.ignore_eos
        tasks = []
        if rows is not None:
            for i in range(n_requests):
                row = rows[i % len(rows)]
                sp = row["conversations"][0]["value"]
                u = _route_url(urls, args.routing, None, i)
                tasks.append(one_request(session, sem, u, args.auth, args.region,
                                         args.model, sp, row["conversations"][1]["value"],
                                         args.max_tokens, args.timeout, ieos))
        elif args.adapters:
            idxs = (zipf_indices(args.adapters, args.zipf, n_requests)
                    if args.zipf else [i % args.adapters for i in range(n_requests)])
            for i in range(n_requests):
                model = f"adapter-{idxs[i]}"
                u = _route_url(urls, args.routing, idxs[i], i)
                tasks.append(one_request(session, sem, u, args.auth, args.region,
                                         model, None, user, args.max_tokens, args.timeout, ieos))
        else:
            for i in range(n_requests):
                u = _route_url(urls, args.routing, None, i)
                tasks.append(one_request(session, sem, u, args.auth, args.region,
                                         args.model, None, user, args.max_tokens,
                                         args.timeout, ieos))

        raw_results = await asyncio.gather(*tasks, return_exceptions=True)
    dur = time.perf_counter() - t0

    # 例外で返ってきたものも error dict に正規化 (ステージ全体は落とさない)
    results = []
    for r in raw_results:
        if isinstance(r, dict):
            results.append(r)
        else:
            results.append({"error": type(r).__name__, "code": None,
                            "ttft_ms": None, "tpot_ms": None, "total_ms": None})

    ok = [r for r in results if r["error"] is None]
    err = [r for r in results if r["error"] is not None]
    n_503 = sum(1 for r in err if r.get("code") == 503)
    err_types = {}
    for r in err:
        err_types[r["error"]] = err_types.get(r["error"], 0) + 1
    good = [r for r in ok if r["ttft_ms"] is not None and r["ttft_ms"] <= args.slo_ttft_ms
            and r["tpot_ms"] is not None and r["tpot_ms"] <= args.slo_tpot_ms]

    ttfts = sorted(r["ttft_ms"] for r in ok if r["ttft_ms"] is not None)
    tpots = sorted(r["tpot_ms"] for r in ok if r["tpot_ms"] is not None)
    out_tps = sum(r.get("out_tok", 0) or 0 for r in ok) / dur if dur else 0

    return {
        "concurrency": concurrency, "n_requests": n_requests, "duration_s": round(dur, 2),
        "n_ok": len(ok), "n_error": len(err), "n_503": n_503, "err_types": err_types,
        "ttft_p50": round(pct(ttfts, 0.50)) if ttfts else None,
        "ttft_p90": round(pct(ttfts, 0.90)) if ttfts else None,
        "ttft_p99": round(pct(ttfts, 0.99)) if ttfts else None,
        "tpot_p50": round(pct(tpots, 0.50), 1) if tpots else None,
        "tpot_p90": round(pct(tpots, 0.90), 1) if tpots else None,
        "tpot_p99": round(pct(tpots, 0.99), 1) if tpots else None,
        "out_tok_per_s": round(out_tps),
        "n_good": len(good),
        "goodput_req_s": round(len(good) / dur, 2) if dur else 0,
        "goodput_pct": round(100 * len(good) / len(results), 1),
    }


async def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base-url", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--auth", choices=["sigv4", "bearer", "none"], default="none")
    p.add_argument("--region", default="us-west-2")
    p.add_argument("--dataset", default=None, help="per-tenant distinct system prompt JSONL (Bedrock)")
    p.add_argument("--adapters", type=int, default=0, help="vLLM: model=adapter-0..N-1")
    p.add_argument("--zipf", type=float, default=0.0, help="adapter 選択の Zipf s (0=uniform)")
    p.add_argument("--concurrency", type=int, nargs="+", default=[10, 50, 100, 200, 400])
    p.add_argument("--requests-per-stage", type=int, default=400)
    p.add_argument("--max-tokens", type=int, default=64)
    p.add_argument("--slo-ttft-ms", type=float, default=2000)
    p.add_argument("--slo-tpot-ms", type=float, default=80)
    p.add_argument("--timeout", type=float, default=180)
    p.add_argument("--ignore-eos", action="store_true",
                   help="自ホスト: 出力長を max_tokens に固定し TPOT を安定計測 (Bedrock は不可)")
    p.add_argument("--routing", choices=["roundrobin", "affinity"], default="roundrobin",
                   help="--base-url がカンマ区切り複数のとき: roundrobin=req循環 / affinity=adapter固定")
    p.add_argument("--input-tokens", type=int, default=0,
                   help="limit 探索用: N トークン相当の合成 user prompt を生成 (dataset/adapter 不使用時)")
    p.add_argument("--out", default=None)
    args = p.parse_args()

    rows = load_dataset(args.dataset) if args.dataset else None

    print(f"# target={args.base_url} model={args.model} auth={args.auth} "
          f"SLO(ttft<={args.slo_ttft_ms}ms,tpot<={args.slo_tpot_ms}ms)")
    print("conc | n | dur_s | ok | err | 503 | TTFT p50/p90/p99 | TPOT p50/p90/p99 | "
          "out_tok/s | good | goodput_req/s | good%")
    def dump(stages):
        if args.out:
            os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
            with open(args.out, "w") as f:
                json.dump({"config": vars(args), "stages": stages}, f, indent=2)

    stages = []
    for c in args.concurrency:
        try:
            st = await run_stage(args, rows, c, args.requests_per_stage)
        except Exception as e:
            print(f"{c:4} | STAGE FAILED: {type(e).__name__}: {str(e)[:120]}")
            dump(stages)  # ここまでの部分結果を保存
            continue
        stages.append(st)
        et = ",".join(f"{k}:{v}" for k, v in st["err_types"].items()) or "-"
        print(f"{st['concurrency']:4} | {st['n_requests']:4} | {st['duration_s']:6} | "
              f"{st['n_ok']:3} | {st['n_error']:3} | {st['n_503']:3} | "
              f"{st['ttft_p50']}/{st['ttft_p90']}/{st['ttft_p99']} | "
              f"{st['tpot_p50']}/{st['tpot_p90']}/{st['tpot_p99']} | "
              f"{st['out_tok_per_s']:6} | {st['n_good']:3} | "
              f"{st['goodput_req_s']:6} | {st['goodput_pct']}% | err={et}")
        dump(stages)  # 各ステージ完了ごとに逐次保存 (途中失敗でもデータが残る)

    dump(stages)
    if args.out:
        print(f"[OK] {args.out}")


if __name__ == "__main__":
    asyncio.run(main())
