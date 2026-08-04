# 30B MoE の反復崩壊は sharding が原因だった (2026-08-04)

> **データ裏付け: 一次データ** — `results/*.summary.json` は本 probe が直接生成したもので、
> 生成テキスト全文 (`*.samples.jsonl`、各 0.8-1.3MB) はクラスタの `/fsx/moe-probe/results/`
> にある。Capacity Block 終了で消えるため、要約 JSON のみを repo に入れている。
> 反復判定は miles の `has_repetition` を逐語移植した `repetition.py` で行い、
> 移植の同一性は 6 ケースで実機検証済み (`PORT_IDENTICAL: True`)。

## 何を調べたのか

miles の GRPO で Qwen3-30B-A3B (MoE) を回すと、**optimizer step を 1 回も踏む前から**
生成が反復ループに入り、reward が常に 0 になる。dense の 4B/8B は同一ハーネスで正常に動く。
過去に 4 つの仮説を実測で否定していた (`../h200_results/P2R_30B_INVALID.md`)。

| 仮説 | 検証 | 結果 |
|---|---|---|
| 応答長の上限不足 | 8192 -> 16384 | 否定 (打ち切り率 0.992 不変) |
| trainer/engine の重み不一致 | `--check-weight-update-equal` | 否定 (通過) |
| サンプリング温度が高すぎる | 1.0 -> 0.6 | 否定 (反復率 0.6328 不変) |
| モデルファイルの破損 | config 比較 | 否定 |

残っていた次の一手は「**miles の GRPO 経路の外**で、SGLang 単体に同じ checkpoint を
サーブさせて反復が再現するか」だった。`repetition_frac` は SGLang が生成したテキストに
対して計算されるので、再現すれば原因は miles の訓練ループの外に確定する。

## 実験の設計

5 セル。各セルが 1 軸だけを動かす。**結果が出る前に「この結果なら何が言えるか」を宣言**して
から走らせた (`probe.py` の docstring に記録)。

| cell | engine | TP | EP | moe_runner_backend | sampling | 動かす軸 |
|---|---|---|---|---|---|---|
| `A_repro` | SGLang | 4 | 2 | triton | miles 既定 | (miles と完全同一) |
| `B_tp1` | SGLang | **1** | **1** | triton | miles 既定 | **sharding** |
| `C_backend` | SGLang | 4 | 2 | **既定(auto)** | miles 既定 | backend |
| `D_sampling` | SGLang | 4 | 2 | triton | **Qwen 推奨** | sampling |
| `E_dense` | SGLang | 4 | 1 | 既定 | miles 既定 | 対照群 (8B dense) |

各セル 32 プロンプト、max_new_tokens 8192、DAPO-Math の先頭から順に。

## 結果

| cell | `repetition_frac` | 最長連続反復 | finish_reason | 判定 |
|---|---|---|---|---|
| `A_repro` | **0.875** | 4083 回 | length 32/32 | miles を再現 (実測 0.633 を上回る) |
| `D_sampling` | **0.875** | 10000 回 | length 31, stop 1 | sampling は原因でない |
| `C_backend` | **0.844** | 8151 回 | length 32/32 | backend は原因でない |
| **`B_tp1`** | **0.000** | **2** | length 24, stop 8 | **sharding が原因** |
| `E_dense` | 0.000 | 2 | length 26, stop 6 | dense は健全 |

**TP4/EP2 を TP1/EP1 に落とした瞬間に反復が完全に消えた。** 同じモデル・同じ backend・
同じ sampling で、sharding だけが違う。

### 生成テキストの実物

圧縮率は間接指標なので、実際に何が繰り返されているかを確認した。

```
A_repro idx=1  : " think think think think ..."  x1666
A_repro idx=27 : " of the of the of the ..."     x1428
A_repro idx=29 : "1\n1\n1\n1\n ..."              x4083
A_repro idx=3  : "‖‖‖‖‖‖‖ ..."
```

TP1 では正常に解答していた。

```
B_tp1 idx=3 : "... So the next 6 cards are placed in boxes: ... $$\boxed{3}$$"
B_tp1 idx=6 : "... Thus, the minimal possible value of d is 10. ... $$\boxed{10}$$"
```

### 反復判定そのものの限界も分かった

`has_repetition` は 10000 文字以下を無条件に False にする。`A_repro` で判定 False だった
4 サンプルは**実際には激しく反復していた** (idx=29 は `"1\n"` を 4083 回) が、
末尾 8284 文字で閾値未満だったため検出漏れしていた。つまり **miles の 0.633 も、
この probe の 0.875 も、真の反復率の下限である**。

一方 `B_tp1` は `over_10k_frac = 1.000` (全サンプルが 10000 文字超) なので、
0.000 は偽陰性ではない。真に反復していない。

## 結論と、まだ言えないこと

**言える。**

- 原因は miles の訓練ループの外にある。GRPO・weight sync・Megatron 側は無関係。
  これは 4 つの仮説がすべて空振りした理由を説明する (すべて miles 内部を疑っていた)。
- 原因は MoE の **TP/EP sharding 経路**にある。同一 checkpoint・同一 backend・同一 sampling で
  TP4/EP2 だけが壊れ、TP1/EP1 は健全。
- sampling params は原因でない。Qwen 公式推奨値 (temp 0.6 / top_p 0.95 / top_k 20) にしても
  `repetition_frac` は 0.875 で動かない。これは web 調査で最有力だった仮説の棄却である。
- `moe_runner_backend` の明示指定も原因でない。既定 (auto) に戻しても 0.844。

**言えない。**

- sharding 経路の**どこ**が壊れているか。TP と EP のどちらが効いているかも分離していない
  (TP4/EP2 -> TP1/EP1 で 2 軸を同時に動かした)。
- upstream のどの issue に対応するか。web 調査で構造的に同型の事例
  (SGLang PR #28244: Qwen3-30B-A3B で TP=8 時に kernel フォールバックと重みレイアウトが
  食い違い garbled 出力) を見つけたが、あれは ROCm/aiter 経路であり、この環境 (H200/CUDA) では
  `_use_aiter` が常に False なので同じ経路は発火しない。**別の機構である。**

## 次にやるべきこと

1. **TP と EP を分離する。** TP4/EP1 と TP1/EP2 を測れば、どちらの軸が効いているか決まる。
   各セル 5 分程度。
2. TP2/TP8 も測って閾値を探す。`moe_intermediate_size=768` が TP で割られた値
   (TP4 -> 192、TP8 -> 96) と kernel の alignment 要求の関係を疑う根拠になる。
3. 特定できたら upstream (sglang-project/sglang) に issue を出す。再現手順は
   `probe.py --cell A_repro` で 32 サンプル 5 分なので、報告として十分に軽い。

## 実行方法

```bash
# 隔離 namespace と probe pod (既存の実験クラスタに影響しない)
kubectl apply -f k8s/00-namespace-and-fsx.yaml
kubectl apply -f k8s/10-probe-pod.yaml

# 反復判定の移植が miles と一致することを先に確認する
kubectl exec -n moe-probe moe-probe -- bash -lc 'cd /fsx/moe-probe/scripts && python3 -c "
import sys; sys.path[:0] = [\".\", \"/root/miles\"]
from repetition import has_repetition as mine
from miles.utils.metric_utils import has_repetition as theirs
t = \"The answer is 42. \" * 900
assert mine(t) == theirs(t) == True; print(\"PORT_IDENTICAL\")"'

# セル実行 (直列。並列だとロードで CPU を取り合う)
bash run_cells.sh A_repro:0,1,2,3 B_tp1:0 C_backend:0,1,2,3 D_sampling:0,1,2,3 E_dense:0,1,2,3

# 生成テキストを目で確認する (圧縮率だけを信用しない)
python3 show_samples.py /fsx/moe-probe/results/A_repro.samples.jsonl 4
```

`k8s/` の 2 マニフェストは既存の miles ハーネスから隔離されている: 専用 namespace
(`moe-probe`)、専用 PV/PVC (`moe-probe-fsx*`)、書き込みは `/fsx/moe-probe/` のみ、
reclaim policy は Retain。probe pod は使い捨てで、結果は FSx に残る。
