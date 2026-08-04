#!/usr/bin/env python3
"""生成テキストを目で見て「本当に degenerate な反復ループなのか」を確認する。

圧縮率 (compression_ratio) は間接指標なので、それだけで「反復した」と結論するのは
危険である。長い定型文 (LaTeX の羅列など) でも圧縮率は上がりうる。
そこで実際に繰り返されている文字列そのものを取り出して見る。
"""
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
top_n = int(sys.argv[2]) if len(sys.argv) > 2 else 5

rows = [json.loads(l) for l in open(path)]
rows.sort(key=lambda r: -r["diag"]["longest_repeat_run"]["repeats"])

print(f"# {path.name}  ({len(rows)} samples)\n")
for r in rows[:top_n]:
    d = r["diag"]
    lr = d["longest_repeat_run"]
    print(f"idx={r['index']} tokens={r['completion_tokens']} chars={d['n_chars']} "
          f"tail_ratio={d['tail_compression_ratio']:.0f} "
          f"period={lr['period']} repeats={lr['repeats']} "
          f"has_repetition={d['has_repetition']}")
    print(f"  repeated unit: {lr['sample']!r}")
    # 末尾 300 文字。degenerate loop なら同じ断片が見えるはず。
    print(f"  tail300: {r['response'][-300:]!r}")
    print()

# 反復していない (has_repetition=False) サンプルも必ず見る。
# 「反復判定が False のものは正常に答えているのか、それとも別の壊れ方か」を確認する。
clean = [r for r in rows if not r["diag"]["has_repetition"]]
print(f"\n## has_repetition=False のサンプル ({len(clean)} 件)\n")
for r in clean[:4]:
    d = r["diag"]
    print(f"idx={r['index']} tokens={r['completion_tokens']} chars={d['n_chars']} "
          f"tail_ratio={d['tail_compression_ratio']:.1f} finish={r['finish_reason']}")
    print(f"  tail300: {r['response'][-300:]!r}")
    print()
