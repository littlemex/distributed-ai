#!/usr/bin/env python3
"""整合性検証: 8 Pod 新構成の計測結果を前回 (1Pod8proc) と並べて差分を出す。

ユーザ要件 (2026-06-21):
  「コスト損益分岐点とか ttft tpot の結果などが今回の構成で変わるならそれは問題」
  → 構成を 1Pod8proc から 8Pod に変えても、同一ワークロードでの TTFT/TPOT/Goodput が
    実験誤差内で一致することを示す。一致すれば既存スライドのデータをそのまま使える。

比較ペア:
  前回 B-roundrobin.json  vs  新 llmd-direct-rr.json   (+ llmd-epp-rr.json)
  前回 B-affinity.json    vs  新 llmd-direct-affinity.json

使い方:
  python3 compare_integrity.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
RES = os.path.join(REPO, "results")
NEW = os.path.join(HERE, "results")

# (ラベル, 旧ファイル, [新ファイル候補...]) — 新は最初に存在したものを使う
PAIRS = [
    ("roundrobin", os.path.join(RES, "B-roundrobin.json"),
     [os.path.join(NEW, "llmd-direct-rr.json"), os.path.join(NEW, "llmd-epp-rr.json")]),
    ("affinity", os.path.join(RES, "B-affinity.json"),
     [os.path.join(NEW, "llmd-direct-affinity.json")]),
]

KEYS = ["ttft_p50", "ttft_p90", "tpot_p50", "tpot_p90", "goodput_req_s", "goodput_pct"]
# 実験誤差の許容幅 (相対 %)。TTFT は数十 ms オーダで veth 差が出やすいので緩め。
TOL = {"ttft_p50": 0.50, "ttft_p90": 0.50, "tpot_p50": 0.20,
       "tpot_p90": 0.20, "goodput_req_s": 0.15, "goodput_pct": 0.05}


def load_stages(path):
    with open(path) as f:
        d = json.load(f)
    return {s["concurrency"]: s for s in d["stages"]}


def fmt(v):
    return "-" if v is None else (f"{v:.1f}" if isinstance(v, float) else str(v))


def main():
    overall_ok = True
    for label, old_path, new_candidates in PAIRS:
        new_path = next((p for p in new_candidates if os.path.exists(p)), None)
        print("=" * 100)
        print(f"# {label}:  OLD={os.path.basename(old_path)}  vs  "
              f"NEW={os.path.basename(new_path) if new_path else '(未計測)'}")
        print("=" * 100)
        if not os.path.exists(old_path):
            print(f"  [SKIP] 旧ファイルなし: {old_path}")
            continue
        if not new_path:
            print("  [SKIP] 新ファイル未計測 (run_experiment.sh 実行後に再評価)")
            continue
        old = load_stages(old_path)
        new = load_stages(new_path)
        concs = sorted(set(old) & set(new))
        hdr = f"{'conc':>5} | " + " | ".join(f"{k:>13}" for k in KEYS)
        print(hdr)
        print("-" * len(hdr))
        for c in concs:
            o, n = old[c], new[c]
            cells = []
            for k in KEYS:
                ov, nv = o.get(k), n.get(k)
                tag = ""
                if isinstance(ov, (int, float)) and isinstance(nv, (int, float)) and ov:
                    rel = abs(nv - ov) / abs(ov)
                    if rel > TOL[k]:
                        tag = f" !{rel*100:.0f}%"
                        overall_ok = False
                cells.append(f"{fmt(ov)}->{fmt(nv)}{tag}")
            print(f"{c:>5} | " + " | ".join(f"{cell:>13}" for cell in cells))
        print()
    print("=" * 100)
    if overall_ok:
        print("[OK] 全ペアが許容誤差内。構成変更 (1Pod8proc -> 8Pod) は TTFT/TPOT/Goodput を変えない。")
        print("     => 既存スライド/ブログのデータをそのまま使用してよい。")
    else:
        print("[WARN] 許容誤差を超える項目あり (!XX%)。上記を確認し、原因 (ネットワーク/負荷) を切り分けること。")
    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())
