#!/usr/bin/env python3
"""inference-perf の load.lora_traffic_split を Zipf 分布で生成する。

テナント人気は現実には均一でなく偏る (少数の hot テナント)。Zipf(s=1.1) で
adapter-0 が最も人気 → adapter-(n-1) が最も不人気、という traffic 比率を作る。
これにより GPU hot-set のヒット率が均一分布より大幅に上がり、affinity routing の
効果 (§1 論点2) が現実的に評価できる。

出力: lora_split_{n}.yaml (n=100/500/1000)。これを inference-perf の config の
load.lora_traffic_split にマージする (configs/*.yaml 参照)。

使い方:
  python gen_zipf_lora_split.py                 # n=100/500/1000, s=1.1
  python gen_zipf_lora_split.py --n 1000 --s 1.1
"""
import argparse

import yaml


def zipf_weights(n: int, s: float = 1.1) -> list:
    raw = [1.0 / (k ** s) for k in range(1, n + 1)]
    total = sum(raw)
    return [w / total for w in raw]


def gen_lora_traffic_split(n: int, s: float = 1.1) -> list:
    weights = zipf_weights(n, s)
    rounded = [round(w, 6) for w in weights]
    diff = round(1.0 - sum(rounded), 6)  # 丸め誤差を最終要素で吸収し sum=1.0 に
    rounded[-1] = round(rounded[-1] + diff, 6)
    return [{"name": f"adapter-{i}", "split": rounded[i]} for i in range(n)]


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--n", type=int, nargs="*", default=[100, 500, 1000])
    p.add_argument("--s", type=float, default=1.1)
    args = p.parse_args()

    for n in args.n:
        split = gen_lora_traffic_split(n, s=args.s)
        top10pct = sum(e["split"] for e in split[: max(1, n // 10)])
        top16 = sum(e["split"] for e in split[:16])
        print(f"N={n}: top 10%={top10pct:.3f}  top-16={top16:.3f}")
        out = f"lora_split_{n}.yaml"
        with open(out, "w") as f:
            yaml.dump({"lora_traffic_split": split}, f, default_flow_style=False)
        print(f"  [OK] {out}")
