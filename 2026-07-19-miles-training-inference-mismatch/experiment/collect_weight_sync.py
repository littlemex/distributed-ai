#!/usr/bin/env python3
"""weight sync の測定値を TensorBoard から集め、定常値を判定して表にする。

なぜ専用のスクリプトが必要か
----------------------------
この study は当初、weight sync の値を `ray job logs | grep elapsed_s` で手で拾っていた。
それだと 3 つの問題がある。

1. Ray のログは重複抑制する (`[repeated 7x across cluster]`)。同じ値なら 1 行に畳まれるので
   「全 rank を見た」と言えるのは値が一致しているときだけで、一致していない場合は
   一部 rank が消える。どちらなのかは grep の結果からは区別できない。
2. 「定常値」の定義が人間の目に委ねられる。B300 の測定では 4 周目以降が定常だったのに、
   H200 では 3 周しか回さずに 2-3 周目を「定常」と呼んでいた。自分の過去の観測と矛盾する
   基準を、そのつもりなく使っていた。
3. ジョブが消えるとログも消える。TensorBoard の event file は /fsx に残る。

そこで event file を一次ソースにし、定常判定を機械化する。

何を測っているか (ここが結論の解釈に直結する)
---------------------------------------------
miles は 2 つの timer を出す。

  perf/update_weights_time                 `update_weights()` メソッド全体 (actor.py:568)
  perf/update_weights_implementation_time  転送本体のみ (mixin.py:311)

**後者は disaggregated 経路にしか存在しない。** colocated 側 (update_weight_from_tensor.py) は
この timer を持たない。したがって:

  - `update_weights_time` は両方式にあるので比較できるが、colocated 側だけが
    pause_generation + flush_cache + begin/end_weight_update + gloo barrier x3 を
    含む (update_weight_from_tensor.py:213-215, 258-263)。**flush_cache は KV cache プール
    全体を破棄するので、コストは mem-fraction に比例する。**
  - つまり両方式の `update_weights_time` の差は「転送方式の差」ではなく
    「転送方式の差 + colocated 側の pause/flush の費用」である。

このスクリプトは両方を出し、disaggregated では total と implementation の差
(= lock 取得 + Ray ラウンドトリップ) も出す。差を「方式差」と呼ぶ前に、
何が含まれているかが表から読めるようにするのが目的である。
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import statistics
import sys

# 定常判定のパラメータ。
#
# WARMUP_DISCARD: 先頭何サンプルを捨てるか。
#   B300 の測定 (2026-06-21-slime-rl-weight-sync-b300/results/WEIGHT_SYNC_RESULTS.md) では
#   1 周目が接続確立で 2.4-2.9s、2-3 周目が過渡、4 周目以降が安定だった。同じ基準を使う。
#   NCCL の lazy init、CUDA graph capture、アロケータのウォームアップは 2-3 周目に残りうる。
WARMUP_DISCARD = 3
# MIN_STEADY_SAMPLES: 定常と主張するのに必要な最小サンプル数。
#   2 サンプルでは分散すら言えないので 4 を下限にする。これを満たさない run は
#   verdict INSUFFICIENT にして、数値は出すが「定常」とは呼ばない。
MIN_STEADY_SAMPLES = 4
# STEADY_CV_MAX: 定常域の変動係数の上限。これを超えたら STEADY と呼ばない。
STEADY_CV_MAX = 0.05
# TREND_TOL: 単調トレンドの許容。定常域の前半平均と後半平均の相対差がこれを超えたら
#   まだ収束していないと見なす。
TREND_TOL = 0.10

TOTAL_KEY = "perf/update_weights_time"
IMPL_KEY = "perf/update_weights_implementation_time"


def read_series(tb_dir: str, key: str) -> list[tuple[int, float]]:
    """TensorBoard event file から (step, value) の系列を読む。

    1 つの run が複数の event file を持つことがある (head と worker が別々に書く、
    再起動で追加される)。同じ step が複数ファイルに出た場合は後勝ちにせず、
    **重複を検出して報告する**: 黙って片方を選ぶと、どちらの run の値を見ているのか
    わからなくなる。この study は過去に「別 run の event file と照合していた」事故を
    verify_results.py の AMBIGUOUS_PAIRING で塞いだので、同じ穴を開けない。
    """
    from tensorboard.backend.event_processing import event_accumulator as ea

    by_step: dict[int, list[float]] = {}
    for path in sorted(glob.glob(os.path.join(tb_dir, "events*"))):
        acc = ea.EventAccumulator(path, size_guidance={"scalars": 100000})
        acc.Reload()
        if key not in acc.Tags()["scalars"]:
            continue
        for s in acc.Scalars(key):
            by_step.setdefault(s.step, []).append(float(s.value))

    out = []
    for step in sorted(by_step):
        vals = by_step[step]
        # 同じ step に複数の値がある場合、値が一致していれば同じ測定の重複書き込みなので
        # 1 つにまとめて良い。食い違っていれば別 run の混在なので隠さずに落とす。
        if len({round(v, 6) for v in vals}) > 1:
            raise ValueError(
                f"{tb_dir}: step {step} of {key} has conflicting values {vals}; "
                "this looks like two runs writing into one tb dir"
            )
        out.append((step, vals[0]))
    return out


def classify(series: list[tuple[int, float]]) -> dict:
    """系列を初回 / 過渡 / 定常に分け、定常と呼べるかを判定する。"""
    values = [v for _, v in series]
    n = len(values)
    res = {
        "n_samples": n,
        "first": values[0] if values else None,
        "all": values,
        "warmup_discarded": min(WARMUP_DISCARD, n),
    }
    steady = values[WARMUP_DISCARD:]
    res["n_steady"] = len(steady)
    res["steady"] = steady

    if not steady:
        res["verdict"] = "NO_STEADY_SAMPLES"
        return res

    med = statistics.median(steady)
    res["median"] = med
    res["min"] = min(steady)
    res["max"] = max(steady)
    # weight sync は最遅 rank で律速されるので max も併記する。ただし TB の値は
    # rank 0 が書いたものなので、これは「呼び出し間の最大」であって
    # 「rank 間の最大」ではない。混同しないよう rank_scope に明記する。
    res["rank_scope"] = "writer rank only (TB is written by one rank)"

    if len(steady) < 2:
        res["cv"] = None
        res["verdict"] = "INSUFFICIENT"
        res["why"] = (
            f"only {len(steady)} sample(s) after discarding {WARMUP_DISCARD} warmup; "
            f"need >= {MIN_STEADY_SAMPLES} to call it steady"
        )
        return res

    mean = statistics.fmean(steady)
    sd = statistics.stdev(steady)
    cv = (sd / mean) if mean else float("inf")
    res["mean"] = mean
    res["stdev"] = sd
    res["cv"] = cv

    # 単調トレンドの検査: 前半と後半で平均が動いていないか。
    half = len(steady) // 2
    if half >= 1:
        early = statistics.fmean(steady[:half])
        late = statistics.fmean(steady[half:])
        drift = abs(late - early) / early if early else float("inf")
        res["drift"] = drift
    else:
        drift = 0.0
        res["drift"] = None

    if len(steady) < MIN_STEADY_SAMPLES:
        res["verdict"] = "INSUFFICIENT"
        res["why"] = (
            f"{len(steady)} steady samples < {MIN_STEADY_SAMPLES}; the number is real "
            "but 'steady' is not established"
        )
    elif cv > STEADY_CV_MAX:
        res["verdict"] = "NOT_STEADY"
        res["why"] = f"CV {cv:.3f} > {STEADY_CV_MAX}"
    elif drift > TREND_TOL:
        res["verdict"] = "NOT_STEADY"
        res["why"] = f"drift {drift:.3f} > {TREND_TOL} (still converging)"
    else:
        res["verdict"] = "STEADY"
    return res


def analyse(tb_dir: str) -> dict:
    out = {"tb_dir": tb_dir, "exists": os.path.isdir(tb_dir)}
    if not out["exists"]:
        out["verdict"] = "MISSING"
        return out

    total = read_series(tb_dir, TOTAL_KEY)
    if not total:
        out["verdict"] = "NO_METRIC"
        out["why"] = f"{TOTAL_KEY} not present in any event file"
        return out
    out["total"] = classify(total)

    impl = read_series(tb_dir, IMPL_KEY)
    if impl:
        out["impl"] = classify(impl)
        # total - impl は colocated には無い内訳。disaggregated では
        # lock 取得と Ray ラウンドトリップに相当する。
        if out["total"].get("median") is not None and out["impl"].get("median") is not None:
            out["overhead_median"] = out["total"]["median"] - out["impl"]["median"]
    else:
        # colocated 経路はこの timer を持たない (mixin.py:311 は distributed 側のみ)。
        # 「無い」ことがそのまま「pause/flush が total に含まれていて分離できない」
        # という意味になるので、欠損ではなく構造的な事実として記録する。
        out["impl"] = None
        out["impl_absent_reason"] = (
            "update_weights_implementation timer exists only on the distributed path "
            "(mixin.py:311); on the colocated path pause_generation + flush_cache + "
            "begin/end_weight_update are inside the total and cannot be separated from it"
        )
    return out


def fmt(x, nd=4):
    return "-" if x is None else f"{x:.{nd}f}"


def main():
    ap = argparse.ArgumentParser(
        description="Collect weight sync timings from TensorBoard and judge steadiness."
    )
    ap.add_argument("cells", nargs="+",
                    help="tb dir paths, or name=path pairs for nicer labels")
    ap.add_argument("--json", help="also write the full result as JSON here")
    a = ap.parse_args()

    results = []
    for spec in a.cells:
        name, _, path = spec.partition("=")
        if not path:
            name, path = os.path.basename(spec.rstrip("/")), spec
        try:
            r = analyse(path)
        except ValueError as e:
            r = {"tb_dir": path, "verdict": "CONFLICT", "why": str(e)}
        r["cell"] = name
        results.append(r)

    print(f"{'cell':34s} {'verdict':12s} {'first':>8s} {'med':>8s} {'min':>8s} "
          f"{'max':>8s} {'CV':>7s} {'n_st':>5s} {'impl_med':>9s}")
    print("-" * 112)
    for r in results:
        t = r.get("total") or {}
        i = r.get("impl") or {}
        print(f"{r['cell']:34s} {(t.get('verdict') or r.get('verdict','?')):12s} "
              f"{fmt(t.get('first'), 3):>8s} {fmt(t.get('median'), 3):>8s} "
              f"{fmt(t.get('min'), 3):>8s} {fmt(t.get('max'), 3):>8s} "
              f"{fmt(t.get('cv'), 3):>7s} {str(t.get('n_steady', '-')):>5s} "
              f"{fmt(i.get('median'), 3):>9s}")

    print()
    for r in results:
        t = r.get("total") or {}
        if t.get("why"):
            print(f"  {r['cell']}: {t['why']}")
        if r.get("why"):
            print(f"  {r['cell']}: {r['why']}")
        if r.get("impl") is None and r.get("impl_absent_reason"):
            print(f"  {r['cell']}: no impl timer -- {r['impl_absent_reason']}")

    print()
    print("READ THIS BEFORE QUOTING THE NUMBERS")
    print("  'med' is the median of the samples AFTER discarding the first "
          f"{WARMUP_DISCARD} (warmup).")
    print("  STEADY requires >= {} samples, CV <= {}, and no drift > {}."
          .format(MIN_STEADY_SAMPLES, STEADY_CV_MAX, TREND_TOL))
    print("  The colocated total INCLUDES pause_generation + flush_cache; the "
          "disaggregated total does NOT.")
    print("  flush_cache drops the whole KV pool, so its cost scales with "
          "--sglang-mem-fraction-static.")
    print("  A colocated-vs-disaggregated difference measured at DIFFERENT mem "
          "fractions is confounded.")

    if a.json:
        with open(a.json, "w") as f:
            json.dump(results, f, indent=2)
        print(f"\nwrote {a.json}")

    # 定常と言えないセルがあれば非ゼロで返す。CI や運用スクリプトが
    # 「全セル定常」を前提にできるようにする。
    bad = [r["cell"] for r in results
           if (r.get("total") or {}).get("verdict") not in ("STEADY",)]
    if bad:
        print(f"\nNOT STEADY (or unusable): {', '.join(bad)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
