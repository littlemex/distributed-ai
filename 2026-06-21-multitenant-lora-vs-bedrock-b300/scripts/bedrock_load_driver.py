#!/usr/bin/env python3
"""Bedrock (Approach A) 負荷ドライバ。inference-perf が shareGPT JSONL の system
field を OpenAI messages[0].role='system' に正しくマップできない場合 (§11 open Q)
の代替。Gemma 4 は bedrock-mantle の OpenAI 互換 Chat Completions のみ対応。

確定事実 (F1/F5):
  - エンドポイント: https://bedrock-mantle.{region}.api.aws/openai/v1
  - InvokeModel/Converse 非対応。openai SDK で叩く。
  - prompt caching なし → 毎回フル input price。

503 throttle 対策: max_retries + concurrency を ramp して計測する (§7)。
本ドライバは「achievable goodput vs concurrency の 503 クリップ点」(§9 論点1) の
データ取得を兼ねる。エラー(503含む)は error として記録し good/all_attempted を出す。

環境変数:
  BEDROCK_BASE_URL  例: https://bedrock-mantle.us-west-2.api.aws/openai/v1
  BEDROCK_API_KEY   Bedrock long-term API key

使い方:
  python bedrock_load_driver.py --dataset bedrock_dataset_long_1000tenants.jsonl \
      --model google.gemma-4-31b --concurrency 100 --max-tokens 128
"""
import argparse
import asyncio
import dataclasses
import json
import os
import time
from typing import Optional

from openai import AsyncOpenAI


@dataclasses.dataclass
class Result:
    tenant_id: int
    ttft_ms: float
    total_ms: float
    output_tokens: int
    error: Optional[str]


async def send_one(client: AsyncOpenAI, row: dict, model: str, max_tokens: int) -> Result:
    t0 = time.perf_counter()
    ttft = None
    out_tokens = 0
    tid = row.get("tenant_id", -1)
    try:
        stream = await client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": row["conversations"][0]["value"]},
                {"role": "user", "content": row["conversations"][1]["value"]},
            ],
            max_tokens=max_tokens,
            stream=True,
        )
        async for chunk in stream:
            if ttft is None and chunk.choices:
                ttft = (time.perf_counter() - t0) * 1000
            if chunk.choices and chunk.choices[0].delta.content:
                out_tokens += 1
    except Exception as e:  # 503 throttle 含む
        return Result(tid, 0, 0, 0, str(e))
    return Result(tid, ttft or 0, (time.perf_counter() - t0) * 1000, out_tokens, None)


async def run_benchmark(dataset_file: str, model: str, concurrency: int,
                        max_tokens: int, out_json: Optional[str]) -> list:
    client = AsyncOpenAI(
        base_url=os.environ["BEDROCK_BASE_URL"],
        api_key=os.environ["BEDROCK_API_KEY"],
        max_retries=6,   # 503 throttle 対策
        timeout=120.0,
    )
    with open(dataset_file) as f:
        rows = [json.loads(line) for line in f]

    sem = asyncio.Semaphore(concurrency)

    async def bounded(row):
        async with sem:
            return await send_one(client, row, model, max_tokens)

    t_start = time.perf_counter()
    results = await asyncio.gather(*[bounded(r) for r in rows])
    dur = time.perf_counter() - t_start

    good = [r for r in results if not r.error]
    errors = [r for r in results if r.error]
    n_503 = sum(1 for r in errors if "503" in (r.error or ""))
    ttfts = sorted(r.ttft_ms for r in good)
    n = len(ttfts) or 1

    print(f"concurrency={concurrency}  N_good={len(good)}/{len(results)}  "
          f"errors={len(errors)} (503={n_503})  "
          f"P50={ttfts[n // 2]:.0f}ms  P99={ttfts[int(n * 0.99)]:.0f}ms  "
          f"good_rate={len(good) / dur:.2f} req/s")

    if out_json:
        with open(out_json, "w") as f:
            json.dump({
                "concurrency": concurrency, "model": model, "duration_s": dur,
                "n_total": len(results), "n_good": len(good),
                "n_error": len(errors), "n_503": n_503,
                "results": [dataclasses.asdict(r) for r in results],
            }, f)
        print(f"  [OK] {out_json}")
    return results


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dataset", required=True)
    p.add_argument("--model", default="google.gemma-4-31b")
    p.add_argument("--concurrency", type=int, default=100)
    p.add_argument("--max-tokens", type=int, default=128)
    p.add_argument("--out-json", default=None)
    args = p.parse_args()
    asyncio.run(run_benchmark(args.dataset, args.model, args.concurrency,
                              args.max_tokens, args.out_json))
