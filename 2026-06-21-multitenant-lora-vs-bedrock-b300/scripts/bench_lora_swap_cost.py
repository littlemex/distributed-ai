#!/usr/bin/env python3
"""swap-in 1回の絶対コストをマイクロベンチで直接計測する (§9 論点2)。

「adapter ロード時間は大したことないのでは?」という仮説を一次データで潰す。
単一 vLLM replica に対し、同一プロンプトを固定して adapter 指定だけを変え、TTFT 差から
swap-in コストを抽出する。

3 水準:
  1) hot     : adapter-0 を繰り返しヒット (swap なし) のベースライン TTFT
  2) cpu_swap: max_loras+ 種を round-robin → 毎回 LRU evict + CPU->GPU copy
               (前提: --max-cpu-loras >> --max-loras で全 adapter が CPU 常駐)
  3) disk    : vLLM を --max-cpu-loras == --max-loras で再起動して 2) と同条件
               → CPU キャッシュ無効、毎回 disk read 込み (手動で再起動して --case disk)

swap_cost ~= median(TTFT_swap) - median(TTFT_hot)
出力長は max_tokens=1 + ignore_eos で decode を最小化し prefill+swap を浮かせる。

期待: 数 ms なら「ロード時間は大したことない」=affinity の旨み小。
      数十 ms なら routing が効く。この絶対値が「llm-d は要るのか」の結論を裏付ける。

使い方 (vLLM 起動後、adapter 登録済みの状態で):
  # case 1+2 (CPU 常駐構成: --max-loras 16 --max-cpu-loras 1000 で起動済み)
  python bench_lora_swap_cost.py --port 8000 --max-loras 16 --n-adapters 64
  # case 3 (disk: --max-loras 16 --max-cpu-loras 16 で再起動してから)
  python bench_lora_swap_cost.py --port 8000 --case disk --n-adapters 64
"""
import argparse
import statistics
import time

import requests

BASE_BODY = {
    "messages": [{"role": "user", "content": "hi"}],
    "max_tokens": 1,
    "ignore_eos": True,
    "stream": True,
}


def ttft(adapter: str, port: int) -> float:
    body = dict(BASE_BODY, model=adapter)
    t0 = time.perf_counter()
    with requests.post(f"http://localhost:{port}/v1/chat/completions",
                       json=body, stream=True, timeout=60) as r:
        for line in r.iter_lines():
            if line and line != b"data: [DONE]":
                return (time.perf_counter() - t0) * 1000  # ms to first chunk
    return -1.0


def median_ttft(adapters, port, warmup=3, n=30) -> float:
    for a in adapters[:warmup]:
        ttft(a, port)
    samples = [ttft(adapters[i % len(adapters)], port) for i in range(n)]
    return statistics.median(s for s in samples if s >= 0)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--max-loras", type=int, default=16)
    p.add_argument("--n-adapters", type=int, default=64,
                   help="swap を誘発する distinct adapter 数 (> max_loras にする)")
    p.add_argument("--samples", type=int, default=30)
    p.add_argument("--case", choices=["hot+cpu", "disk"], default="hot+cpu",
                   help="disk は --max-cpu-loras==--max-loras で vLLM 再起動後に実行")
    args = p.parse_args()

    swap_adapters = [f"adapter-{i}" for i in range(args.n_adapters)]

    if args.case == "hot+cpu":
        hot = median_ttft(["adapter-0"], args.port, n=args.samples)
        cpu = median_ttft(swap_adapters, args.port, n=args.samples)
        print(f"hot={hot:.1f}ms  cpu_swap={cpu:.1f}ms  swap_cost(CPU->GPU)~={cpu - hot:.1f}ms")
    else:  # disk
        hot = median_ttft(["adapter-0"], args.port, n=args.samples)
        disk = median_ttft(swap_adapters, args.port, n=args.samples)
        print(f"hot={hot:.1f}ms  disk_swap={disk:.1f}ms  swap_cost(disk->GPU)~={disk - hot:.1f}ms")
