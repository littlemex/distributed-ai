"""miles の反復判定を逐語で移植したもの。

正本は miles の /root/miles/miles/utils/metric_utils.py:66-114 (has_repetition と
compression_ratio)。**この probe が miles の実測値 (30B repetition_frac 0.633、
dense 0.0) と直接比較できるのは、判定が完全に同一である限りにおいてである。**
そのため意図的に 1 文字も変えずに写している。式を「改善」してはいけない。

判定の性質として押さえておくべき点が 2 つある。

1. 10000 文字以下のテキストは無条件に False になる。したがって
   repetition_frac は「反復しているか」ではなく「長く、かつ末尾 10000 文字が
   圧縮率 10 倍を超えるか」を測っている。短くて反復しているテキストは
   検出されない (偽陰性)。
2. 逆に、非常に長い定型的なテキスト (例えば LaTeX の繰り返しや箇条書き) も
   圧縮率が上がりうる。したがって 0.633 という値が「本当に degenerate な
   反復ループ」なのかは、圧縮率だけでなく実際の生成テキストを目で見て
   確認する必要がある。この probe は raw text も必ず保存する。
"""

from typing import Literal


def compression_ratio(
    data: str | bytes,
    *,
    encoding: str = "utf-8",
    algorithm: Literal["zlib", "gzip", "bz2", "lzma"] = "zlib",
    level: int = 9,
) -> tuple[float, float]:
    if isinstance(data, str):
        raw = data.encode(encoding)
    else:
        raw = data

    original = len(raw)
    if original == 0:
        return float("inf"), 0.0

    if algorithm == "zlib":
        import zlib

        compressed = zlib.compress(raw, level)
    elif algorithm == "gzip":
        import gzip

        compressed = gzip.compress(raw, compresslevel=level)
    elif algorithm == "bz2":
        import bz2

        compressed = bz2.compress(raw, compresslevel=level)
    elif algorithm == "lzma":
        import lzma

        compressed = lzma.compress(raw, preset=level)
    else:
        raise ValueError(f"Unsupported algorithm: {algorithm}")

    comp_len = len(compressed)
    if comp_len == 0:
        return float("inf"), 100.0

    ratio = original / comp_len
    savings_pct = 100.0 * (1.0 - comp_len / original)
    return ratio, savings_pct


def has_repetition(text: str):
    if len(text) > 10000 and compression_ratio(text[-10000:])[0] > 10:
        return True
    else:
        return False


# --- 診断用の補助指標 (miles には無い。判定の中身を見るために足す) ---
#
# has_repetition は bool しか返さないので、閾値の「どちら側にどれだけ離れて
# いるか」が見えない。0.633 が閾値ギリギリなのか大きく振り切れているのかは
# 解釈に決定的に効くので、生の圧縮率と長さも併せて記録する。


def repetition_diagnostics(text: str) -> dict:
    n_chars = len(text)
    tail = text[-10000:]
    ratio_tail, savings_tail = compression_ratio(tail) if tail else (float("inf"), 0.0)
    ratio_full, _ = compression_ratio(text) if text else (float("inf"), 0.0)
    return {
        "n_chars": n_chars,
        "over_10k_chars": n_chars > 10000,
        "tail_compression_ratio": ratio_tail,
        "tail_savings_pct": savings_tail,
        "full_compression_ratio": ratio_full,
        "has_repetition": has_repetition(text),
        # 閾値からの距離。1.0 を超えていれば反復判定側。
        "ratio_over_threshold": ratio_tail / 10.0,
        # 最長の繰り返し部分文字列の長さ。圧縮率とは独立な、より直接的な反復の証拠。
        "longest_repeat_run": _longest_repeated_run(tail),
    }


def _longest_repeated_run(text: str, max_period: int = 400) -> dict:
    """末尾テキストの中で「同じ文字列が連続して何回繰り返されているか」を直接測る。

    圧縮率は間接的な指標なので、degenerate loop の直接証拠としてこれも取る。
    period p を 1..max_period で試し、text[-p*k:] が p 周期で反復している
    最大の k を返す。計算量を抑えるため末尾のみ、周期も上限を切る。
    """
    if not text:
        return {"period": 0, "repeats": 0, "sample": ""}
    best = {"period": 0, "repeats": 0, "sample": ""}
    n = len(text)
    for p in range(1, min(max_period, n // 2) + 1):
        unit = text[n - p : n]
        k = 1
        while (k + 1) * p <= n and text[n - (k + 1) * p : n - k * p] == unit:
            k += 1
        if k > 1 and k * p > best["repeats"] * best["period"]:
            best = {"period": p, "repeats": k, "sample": unit[:120]}
    return best
