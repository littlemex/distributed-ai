#!/usr/bin/env python3
"""vLLM の /metrics をポーリングし LoRA swap thrash を観測する (§9)。

vllm:lora_requests_info{running_lora_adapters="..."} の GPU hot-set メンバ変化を
スクレイプ間で差分し、swap-in イベントを推定する。8 replica を個別 scrape
(--data-parallel-size 使用時は不正確との警告があるため、独立 replica を各々叩く)。

round-robin と affinity で swap-in/s を比較すると、affinity が swap を減らすかが見える。

使い方:
  python monitor_lora_swap.py --ports 8000 8001 8002 8003 8004 8005 8006 8007 --interval 2
"""
import argparse
import re
import time

import requests

RUNNING_RE = re.compile(r'running_lora_adapters="([^"]*)"')


def scrape(port: int) -> set:
    try:
        text = requests.get(f"http://localhost:{port}/metrics", timeout=5).text
    except Exception:
        return set()
    m = RUNNING_RE.search(text)
    if m and m.group(1):
        return {a for a in m.group(1).split(",") if a}
    return set()


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--ports", type=int, nargs="+",
                   default=[8000, 8001, 8002, 8003, 8004, 8005, 8006, 8007])
    p.add_argument("--interval", type=float, default=2.0)
    args = p.parse_args()

    prev = {port: set() for port in args.ports}
    swap_totals = {port: 0 for port in args.ports}
    t_start = time.perf_counter()
    print(f"[INFO] monitoring {len(args.ports)} replicas every {args.interval}s (Ctrl-C to stop)")
    try:
        while True:
            for port in args.ports:
                cur = scrape(port)
                new_adapters = cur - prev[port]
                if new_adapters:
                    swap_totals[port] += len(new_adapters)
                    print(f"[port:{port}] swap-in: {len(new_adapters)} "
                          f"({list(new_adapters)[:3]}...)  cumulative={swap_totals[port]}")
                prev[port] = cur
            time.sleep(args.interval)
    except KeyboardInterrupt:
        dur = time.perf_counter() - t_start
        total = sum(swap_totals.values())
        print(f"\n[SUMMARY] {dur:.0f}s, total swap-in={total}, "
              f"rate={total / dur:.2f} swap/s across {len(args.ports)} replicas")
