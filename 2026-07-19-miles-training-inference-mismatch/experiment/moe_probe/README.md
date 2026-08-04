# Qwen3-30B-A3B の反復崩壊は expert parallelism が原因 (2026-08-04)

> **データ裏付け: 一次データ** — `results/*.summary.json` は本 probe が直接生成した。
> 生成テキスト全文 (`*.samples.jsonl`、各 0.8-1.3MB) はクラスタの `/fsx/moe-probe/results/`
> にあり、Capacity Block 終了で消えるため要約 JSON のみを repo に入れている。
> 反復判定は miles の `has_repetition` を逐語移植した `repetition.py` で行い、
> 移植の同一性は 6 ケースで実機検証済み (`PORT_IDENTICAL: True`)。

## 一行で

**`--expert-parallel-size` を 1 より大きくすると Qwen3-30B-A3B の生成が反復ループに陥る。
tensor parallel は無関係で、EP を増やすほど悪化する。**

| EP | TP=1 | TP=4 | TP=8 |
|---|---|---|---|
| **1** | **0.000** | **0.000** | **0.000** |
| **2** | (起動不可) | **0.875** | **0.594** |
| **4** | — | — | **0.844** |

数値は `rollout/repetition_frac` と同一定義の反復率 (32 サンプル)。

## 何を調べたのか

miles の GRPO で Qwen3-30B-A3B (MoE) を回すと、**optimizer step を 1 回も踏む前から**
生成が反復ループに入り reward が常に 0 になる。dense の 4B/8B は同一ハーネスで正常に動く。
過去に 4 つの仮説を実測で否定していた (`../h200_results/P2R_30B_INVALID.md`)。

| 仮説 | 検証 | 結果 |
|---|---|---|
| 応答長の上限不足 | 8192 -> 16384 | 否定 (打ち切り率 0.992 不変) |
| trainer/engine の重み不一致 | `--check-weight-update-equal` | 否定 (通過) |
| サンプリング温度が高すぎる | 1.0 -> 0.6 | 否定 (反復率 0.6328 不変) |
| モデルファイルの破損 | config 比較 | 否定 |

**4 つすべてが miles の内部を疑っていた。** `repetition_frac` は SGLang が生成した
テキストに対して計算されるので、miles の GRPO 経路の外で再現するかを見れば、
原因が訓練ループの内か外かが決まる。それが本 probe である。

## 実験の設計

各セルが 1 軸だけを動かす。**結果を見る前に「この結果なら何が言えるか」を宣言**してから
走らせた (`probe.py` の docstring と `CELLS_TP_EP.md` に記録)。

| cell | model | TP | EP | backend | sampling | 動かす軸 |
|---|---|---|---|---|---|---|
| `A_repro` | 30B MoE | 4 | 2 | triton | miles 既定 | (miles と完全同一) |
| `B_tp1` | 30B MoE | 1 | 1 | triton | miles 既定 | TP と EP を同時に |
| `C_backend` | 30B MoE | 4 | 2 | **既定(auto)** | miles 既定 | backend |
| `D_sampling` | 30B MoE | 4 | 2 | triton | **Qwen 推奨** | sampling |
| `E_dense` | **8B dense** | 4 | 1 | 既定 | miles 既定 | 対照群 |
| `F_tp4_ep1` | 30B MoE | 4 | **1** | triton | miles 既定 | **EP のみ** |
| `G_tp1_ep2` | 30B MoE | **1** | 2 | triton | miles 既定 | TP のみ |
| `H_tp8_ep1` | 30B MoE | **8** | 1 | triton | miles 既定 | TP (EP=1 側) |
| `I_tp8_ep2` | 30B MoE | **8** | 2 | triton | miles 既定 | TP (EP=2 側) |
| `J_tp8_ep4` | 30B MoE | 8 | **4** | triton | miles 既定 | **EP の大きさ** |
| `K_ep2_a2a_deepep` | 30B MoE | 8 | 2 | triton | miles 既定 | all-to-all 実装 |
| `L_ep2_redundant0` | 30B MoE | 8 | 2 | triton | miles 既定 | expert 冗長配置 |

各セル 32 プロンプト、`max_new_tokens` 8192、DAPO-Math の先頭から順、H200 (p5en)。
sampling の「miles 既定」は temperature 1.0 / top_p 1.0 / top_k -1
(miles は `/generate` を使うので `generation_config.json` は読まれない)。

## 結果

| cell | TP | EP | `repetition_frac` | 10k 超の割合 | 最長連続反復 | finish |
|---|---|---|---|---|---|---|
| `B_tp1` | 1 | 1 | **0.000** | 1.000 | 2 | length 24, stop 8 |
| `F_tp4_ep1` | 4 | 1 | **0.000** | 0.969 | 2 | length 23, stop 9 |
| `H_tp8_ep1` | 8 | 1 | **0.000** | 1.000 | 2 | length 24, stop 8 |
| `A_repro` | 4 | 2 | 0.875 | 0.875 | 4083 | length 32 |
| `C_backend` | 4 | 2 | 0.844 | 0.875 | 8151 | length 32 |
| `D_sampling` | 4 | 2 | 0.875 | 0.875 | 10000 | length 31, stop 1 |
| `I_tp8_ep2` | 8 | 2 | 0.594 | 0.719 | 2500 | length 31, stop 1 |
| `J_tp8_ep4` | 8 | 4 | 0.844 | 0.875 | 3333 | length 32 |
| `L_ep2_redundant0` | 8 | 2 | 0.781 | 0.875 | 4761 | length 30, stop 2 |
| `E_dense` (8B) | 4 | 1 | 0.000 | 1.000 | 2 | length 26, stop 6 |

`G_tp1_ep2` と `K_ep2_a2a_deepep` は起動しなかった (後述)。

### EP が原因である (TP ではない)

- **EP=1 の 3 セルはすべて 0.000。** TP を 1 / 4 / 8 と変えても健全。
- **EP>1 の 5 セルはすべて 0.594 以上。** TP を 4 / 8 と変えても壊れる。
- `A_repro` (TP4/EP2) と `F_tp4_ep1` (TP4/EP1) は **EP の値だけが違う**。0.875 対 0.000。
  `H_tp8_ep1` と `I_tp8_ep2` も同様に EP だけが違う。0.000 対 0.594。

`B_tp1` が健全だったのは TP を落としたからではなく、EP を 1 にしたからだった。

### EP を増やすと悪化する (用量反応)

TP=8 で EP だけを振ると単調に増える。

| EP | `repetition_frac` | 最長連続反復 |
|---|---|---|
| 1 | 0.000 | 2 |
| 2 | 0.594 | 2500 |
| 4 | 0.844 | 3333 |

「特定の構成で偶発的に壊れる」のではなく、**EP の分割数に比例して悪化する**。

### TP1/EP2 は表現できない

`G_tp1_ep2` は起動時に落ちた。

```
sglang/srt/entrypoints/engine.py:1496 in _compute_parallelism_ranks
ZeroDivisionError: integer division or modulo by zero
```

EP は TP に従属する構造なので、TP1 で EP2 は作れない。`CELLS_TP_EP.md` で
「失敗した場合はそれ自体が構造の証拠になる」と予告していた通りで、
逆向きの検証は `H`/`I` (TP8 固定で EP を振る) が代替している。
なお **入力検証の不足としては報告に値する**: 不可能な組み合わせが
`ZeroDivisionError` になるのは利用者に原因が伝わらない。

### EP の内訳: expert 配置オプションでは解消しない

EP>1 で変わるものを 1 つずつ潰そうとした。

`L_ep2_redundant0` は `ep_num_redundant_experts=0` を明示した (冗長 expert を持たせない)。
**反復は 0.781 で残った。** expert の冗長配置は原因ではない。

`K_ep2_a2a_deepep` は all-to-all 実装を `deepep` に差し替えようとしたが、
**その経路自体が壊れていて起動しなかった。**

```
sglang/srt/models/qwen3_moe.py:382 in forward_deepep
AssertionError: forward_deepgemm_masked is deprecated
```

つまり Qwen3-MoE の deepep 経路は、この版では deprecated な関数を呼んでおり使えない。
all-to-all 実装の寄与は測れていない。**これも独立した報告対象である。**

### 生成テキストの実物

圧縮率は間接指標なので、実際に何が繰り返されているかを確認した。

```
A_repro idx=1  : " think think think think ..."  x1666
A_repro idx=27 : " of the of the of the ..."     x1428
A_repro idx=29 : "1\n1\n1\n1\n ..."              x4083
A_repro idx=3  : "‖‖‖‖‖‖‖ ..."
```

EP=1 では正常に解答している。

```
B_tp1 idx=3 : "... So the next 6 cards are placed in boxes: ... $$\boxed{3}$$"
B_tp1 idx=6 : "... Thus, the minimal possible value of d is 10. ... $$\boxed{10}$$"
```

### 反復判定そのものの限界も分かった

`has_repetition` は 10000 文字以下を無条件に False にする。`A_repro` で判定 False だった
4 サンプルは**実際には激しく反復していた** (idx=29 は `"1\n"` を 4083 回) が、
末尾 8284 文字で閾値未満だったため検出漏れした。つまり **miles の 0.633 も本 probe の
0.875 も真の反復率の下限である。**

逆方向の誤りは無い。EP=1 のセルは `over_10k_frac` が 0.969-1.000 (ほぼ全サンプルが
10000 文字超) なので、0.000 は「短すぎて判定されなかった」ではなく真に反復していない。

同一の欠陥指標で比較している限り相対比較の妥当性は保たれるが、
**この反例 (`"1\n"` x4083 が False) はテストケースとして upstream に報告する価値がある。**

## 結論

**言える。**

- 原因は miles の訓練ループの外にある。GRPO・weight sync・Megatron 側は無関係。
  4 つの仮説がすべて空振りした理由もこれで説明がつく (すべて miles 内部を疑っていた)。
- **原因は expert parallelism である。** EP=1 なら TP 1/4/8 すべて健全、
  EP>1 なら TP 4/8 すべて崩壊。EP を増やすほど悪化する。
- sampling は原因でない。Qwen 公式推奨値 (temp 0.6 / top_p 0.95 / top_k 20) でも 0.875。
  **これは Web 調査で最有力だった仮説の棄却である。**
- `moe_runner_backend` の明示指定も原因でない。既定 (auto) に戻しても 0.844。

**言えない。**

- **EP 経路のどこが壊れているか。** EP>1 で変わるのは少なくとも 3 つあり、
  1 つだけ潰せた。
  - expert の冗長配置 -> **否定** (`ep_num_redundant_experts=0` でも 0.781)
  - all-to-all の dispatch/combine -> **未測定** (`deepep` 経路が別のバグで起動しない)
  - expert のグループ分割そのもの / 各 rank の expert 数の減少 -> 未測定
- **他の MoE モデルでも起きるか。** Qwen3-30B-A3B のみで確認した。
- **他のバージョンでも起きるか。** SGLang 0.5.16.dev25+g6460e2c のみ。
- **dense モデルとの厳密な対照は作れない。** dense には expert が無いので EP 軸の
  対照群は原理的に存在しない。`E_dense` は「MoE 固有か」の対照にはなるが EP の効果は測らない。

## 次にやるべきこと

1. **upstream (sglang-project/sglang) に issue を出す。** 再現は
   `probe.py --cell H_tp8_ep1` と `--cell I_tp8_ep2` の対比 (各 5 分) で、
   **EP の値以外は完全に同一**という形になる。EP=4 で悪化する用量反応も添えられる。
2. **EP の内訳を分離する。** 冗長 expert 配置は否定済み (`L_ep2_redundant0` で 0.781)。
   all-to-all 実装は `deepep` 経路が別のバグ (`forward_deepgemm_masked is deprecated`) で
   起動しないため未測定。残る候補は「expert のグループ分割そのもの」と
   「各 rank が持つ expert 数の減少」で、後者は `num_experts` を変えたモデルが要る。
3. `has_repetition` の反例を miles に報告する (10000 文字閾値による偽陰性)。
4. **他の MoE モデル (Qwen3-235B-A22B、Mixtral 等) で再現するか**を見て、
   モデル固有かフレームワーク側かを切り分ける。

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

# EP を分離する最小の 2 セル (これだけで帰属が決まる)
bash run_cells.sh H_tp8_ep1:0,1,2,3,4,5,6,7 I_tp8_ep2:0,1,2,3,4,5,6,7

# 全セル
bash run_cells.sh A_repro:0,1,2,3 B_tp1:0 C_backend:0,1,2,3 D_sampling:0,1,2,3 \
                 E_dense:0,1,2,3 F_tp4_ep1:0,1,2,3 J_tp8_ep4:0,1,2,3,4,5,6,7

# 生成テキストを目で確認する (圧縮率だけを信用しない)
python3 show_samples.py /fsx/moe-probe/results/A_repro.samples.jsonl 4
```

`k8s/` の 2 マニフェストは既存の miles ハーネスから隔離されている: 専用 namespace
(`moe-probe`)、専用 PV/PVC (`moe-probe-fsx*`)、書き込みは `/fsx/moe-probe/` のみ、
reclaim policy は Retain。probe pod は使い捨てで結果は FSx に残る。
