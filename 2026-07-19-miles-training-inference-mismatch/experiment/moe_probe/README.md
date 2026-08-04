# 30B MoE の反復崩壊は expert parallelism (EP) が原因だった (2026-08-04)

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
| `B_tp1` | SGLang | **1** | **1** | triton | miles 既定 | **TP と EP を同時に** |
| `C_backend` | SGLang | 4 | 2 | **既定(auto)** | miles 既定 | backend |
| `D_sampling` | SGLang | 4 | 2 | triton | **Qwen 推奨** | sampling |
| `E_dense` | SGLang | 4 | 1 | 既定 | miles 既定 | 対照群 (8B dense) |
| `F_tp4_ep1` | SGLang | 4 | **1** | triton | miles 既定 | **EP のみ** |
| `G_tp1_ep2` | SGLang | **1** | 2 | triton | miles 既定 | **TP のみ** |

各セル 32 プロンプト、max_new_tokens 8192、DAPO-Math の先頭から順に。
`F` と `G` は `B_tp1` が TP と EP を同時に動かしていたため、1 軸ずつ戻して分離するもの。
事前宣言は `CELLS_TP_EP.md` に、結果を見る前に書いてある。

## 結果

| cell | `repetition_frac` | 最長連続反復 | finish_reason | 判定 |
|---|---|---|---|---|
| `A_repro` | **0.875** | 4083 回 | length 32/32 | miles を再現 (実測 0.633 を上回る) |
| `D_sampling` | **0.875** | 10000 回 | length 31, stop 1 | sampling は原因でない |
| `C_backend` | **0.844** | 8151 回 | length 32/32 | backend は原因でない |
| **`B_tp1`** | **0.000** | **2** | length 24, stop 8 | **この構成では起きない** |
| `E_dense` | 0.000 | 2 | length 26, stop 6 | dense は健全 |
| **`F_tp4_ep1`** | **0.000** | **2** | length 23, stop 9 | **EP が原因。TP は無関係** |
| `G_tp1_ep2` | (起動失敗) | - | - | SGLang が TP1/EP2 を受け付けない |

**TP4/EP2 を TP1/EP1 に落とすと反復が完全に消えた** (`B_tp1`)。ただしこれは TP と EP を
同時に動かしているので、分離セルを追加した。

**`F_tp4_ep1` が決めた: TP4 のまま EP を 2 -> 1 にしただけで反復が消える。** つまり
原因は TP ではなく **EP (expert parallelism)** である。`A_repro` (TP4/EP2) と
`F_tp4_ep1` (TP4/EP1) の差は EP の値だけで、モデル・backend・sampling・TP はすべて同一。

逆向きの `G_tp1_ep2` (TP1/EP2) は SGLang が起動を拒否した:

```
sglang/srt/entrypoints/engine.py:1496 in _compute_parallelism_ranks
ZeroDivisionError: integer division or modulo by zero
```

EP は TP に従属する構造なので TP1 で EP2 は表現できない。これは `CELLS_TP_EP.md` で
「失敗した場合はそれ自体が構造の証拠になる」と予告していた通りで、`F` の結果だけで
帰属は決まる。

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
- **原因は EP (expert parallelism) である。** `A_repro` (TP4/EP2) と `F_tp4_ep1` (TP4/EP1) は
  EP の値だけが違い、前者は 0.875、後者は 0.000。TP・モデル・backend・sampling はすべて同一。
  **TP は無関係**であり、`B_tp1` で見えた改善は EP を 1 に落としたことによるものだった。
- sampling params は原因でない。Qwen 公式推奨値 (temp 0.6 / top_p 0.95 / top_k 20) にしても
  `repetition_frac` は 0.875 で動かない。これは web 調査で最有力だった仮説の棄却である。
- `moe_runner_backend` の明示指定も原因でない。既定 (auto) に戻しても 0.844。

**言えない。**

- **EP 経路のどこが壊れているか。** EP=2 で何が変わるかは 3 つある:
  expert が 2 グループに分割される、all-to-all dispatch/combine が走る、
  各 rank が持つ expert 数が 128 -> 64 になる。どれが原因かは分離していない。
- **EP=4 以上でも同じか。** EP=2 しか測っていない。EP を増やすと悪化するのか、
  それとも EP>1 で一律に壊れるのかは未確認。
- **dense モデルで EP>1 は測れない。** dense には expert が無いので、この軸の対照群は
  原理的に作れない。`E_dense` は「MoE 固有か」の対照群としては機能するが、
  EP の効果を測るものではない。
- upstream のどの issue に対応するか。web 調査で構造的に同型の事例
  (SGLang PR #28244: Qwen3-30B-A3B で TP=8 時に kernel フォールバックと重みレイアウトが
  食い違い garbled 出力) を見つけたが、あれは ROCm/aiter 経路であり、この環境 (H200/CUDA) では
  `_use_aiter` が常に False なので同じ経路は発火しない。**別の機構である。**

## 次にやるべきこと

1. **~~TP と EP を分離する~~ 完了。** EP が原因と確定した (`F_tp4_ep1`)。
2. **EP=4/EP=8 を測る。** EP>1 で一律に壊れるのか、EP に比例して悪化するのかを見る。
   TP8 なら EP4 まで取れる。各セル 5 分程度。
3. **EP の内訳を分離する。** all-to-all dispatch を疑うなら
   `--moe-a2a-backend` (既定 none / deepep 等) を振る。expert 分割そのものを疑うなら
   `--ep-num-redundant-experts` などの配置系オプションを振る。
4. **upstream (sglang-project/sglang) に issue を出す。** 再現手順は
   `probe.py --cell A_repro` (32 サンプル・5 分) と `--cell F_tp4_ep1` の対比だけで、
   EP=2 の有無以外は完全に同一条件なので、報告としては十分に軽く強い。
   併せて `G_tp1_ep2` の `ZeroDivisionError` (TP1/EP2 が
   `_compute_parallelism_ranks` で除算エラーになる) も、入力検証の不足として報告できる。

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
