# P3M: weight sync の方式差を、交絡を潰して測る (2026-08-04)

> **データ裏付け: TB_ONLY (単一ソース)** — 本ファイルの数値は run `p3m_colo_tp1_mf08` /
> `p3m_disagg_tp1_mf08` / `p3m_disagg_tp1_mf085` の TensorBoard event file に由来する。
> 抽出と定常判定は `experiment/collect_weight_sync.py`。判定の定義は同ディレクトリの
> `DATA_STATUS.md`。数値を他の文書へ転記する前に必ず再実行して照合する。

## 何が問題だったか

登壇資料とブログは「colocated (CUDA IPC) は disaggregated (NCCL/EFA) より約 5 倍遅い」と
書いていた。根拠は B300 上の slime 実測 (colocated 1.53s vs disaggregated 0.30s) である。

この主張には**測っていない穴が 2 つ**あった。

1. **H200 の disaggregated を一度も測っていなかった。** H200 側は colocated しか無く、
   しかも H200 colocated (0.40s) は B300 disaggregated (0.30s) とほぼ同水準だったので、
   H200 では方式差がほとんど消える可能性があった。
2. **その穴は recipe の欠陥に由来していた。** `run_grpo_qwen3_4b.sh` は `--colocate` を
   ハードコードし、`COLOCATE` 変数は banner の echo にしか使っていなかった。つまり
   `COLOCATE=false` を書いても disaggregated にはならず、**disaggregated アームは
   このハーネスから到達不能だった**。

さらに測り始めてから 3 つ目の問題が見つかった。

3. **最初の disaggregated 測定 (`p3d_*`) は mem-fraction 0.85、比較相手の colocated は 0.8
   だった。** これは無害な差ではない。colocated 経路だけが sync ごとに
   `pause_generation` と `flush_cache` を呼ぶ (`update_weight_from_tensor.py:213-215`) ので、
   KV プールに関わる設定は**比較対象の量の内側に入る**。

## 測り直した結果

条件: Qwen3-4B、DAPO-Math、GRPO、TP1、LR 1e-6、seed 1234 / rollout-seed 42、dropout 0、
NUM_ROLLOUT=7、H200 (p5en) 2 ノード。colocated は actor 8 GPU と rollout 8 GPU が同一デバイス、
disaggregated は actor 8 GPU (node A) と rollout 8 GPU (node B) で転送は EFA 越しの NCCL。

**mem-fraction を 0.8 に揃えた。** disaggregated 側が KV の余裕を少し手放す方向なので、
既存の colocated 測定 (0.8) との比較可能性を保てる。

| cell | 方式 | mem-frac | 初回 | **定常 median** | min | max | CV | n | verdict |
|---|---|---|---|---|---|---|---|---|---|
| `p3m_colo_tp1_mf08` | colocated | 0.8 | 0.798 | **0.482** | 0.473 | 0.486 | 0.012 | 4 | STEADY |
| `p3m_disagg_tp1_mf08` | disaggregated | 0.8 | 14.414 | **0.170** | 0.166 | 0.172 | 0.013 | 4 | STEADY |

**方式差は 2.84 倍** (0.482 / 0.170)。B300 の 5.1 倍ではない。

### 定常の定義を機械化した

以前は「2-3 周目を定常とみなす」と目で判断していたが、これは自分たちの B300 観測
(4 周目以降が安定) と矛盾していた。`collect_weight_sync.py` は先頭 3 サンプルを warmup として
捨て、残り 4 サンプル以上・CV <= 0.05・前半後半の drift <= 10% を満たしたときだけ `STEADY` と
判定する。**この基準で既存の 3-rollout セルはすべて `NO_STEADY_SAMPLES` になる** —
先頭 3 つを捨てると何も残らないためで、「定常値 0.40s」という過去の記述は根拠が薄かった。

### 初回コストは方式で大きく違う

| 方式 | 初回 | 定常 | 初回の内訳 |
|---|---|---|---|
| colocated | 0.798s | 0.482s | CUDA IPC handle の確立 |
| disaggregated | **14.414s** | 0.170s | NCCL custom process group の確立 |

disaggregated は定常で 2.84 倍速いが、**初回に 14.4 秒払う**。30 step 程度の短い実験では
この償却が効かない場合がある (14.4 + 29x0.17 = 19.3s 対 0.80 + 29x0.48 = 14.7s で、
**30 step では colocated の方が総和は小さい**)。損益分岐は約 44 step。

## 転送本体と付帯処理を分離できた

miles は disaggregated 経路にだけ `perf/update_weights_implementation_time` を出す
(`update_weight_from_distributed/mixin.py:311`)。

| 指標 | disaggregated 定常 |
|---|---|
| `update_weights_time` (メソッド全体) | 0.170s |
| `update_weights_implementation_time` (転送本体) | 0.146s |
| 差 (lock 取得 + Ray ラウンドトリップ) | 0.024s |

転送本体が 86% を占める。一方 **colocated にはこの timer が無い**ので同じ分解ができない。
これは欠損ではなく構造的な非対称である。

## 残る非対称: この 2.84 倍は純粋な「転送方式の差」ではない

`update_weights` の `@timer` は両方式でメソッド全体を包んでおり (`actor.py:568`)、
スコープは同一である。しかし**中身が違う**。

| 処理 | colocated | disaggregated |
|---|---|---|
| `pause_generation` | あり | なし |
| **`flush_cache`** | **あり** | **なし** |
| `begin/end_weight_update` | あり | なし |
| gloo barrier | 3 回 | なし |
| 転送 | CUDA IPC (chunk ごとに `ipc_collect()`) | NCCL broadcast (バッファ一括) |
| engine 側の完了待ち | `ray.get(refs)` | `ray.get(refs)` (`broadcast.py:119`) |

したがって 0.482 対 0.170 の差は「転送方式の差」**プラス** 「colocated 側の pause/flush の
費用」である。`flush_cache` は SGLang の `/flush_cache` への HTTP GET
(`sglang_engine.py:397-409`) で radix cache を破棄する処理であり、KV プールの大きさに
依存しうる。**この分解は未実施**で、`p3m_disagg_tp1_mf085` (mem-fraction 感度) は
その第一歩にすぎない。

## 言えること / 言えないこと

**言える。**

- 両環境で disaggregated の定常 weight sync が速い。倍率は H200/miles で 2.84 倍、
  B300/slime で 5.1 倍。
- 倍率は環境とフレームワークに依存する。単一環境の値を一般化してはいけない。
- disaggregated は初回に 14.4 秒払うので、短い run では総和が逆転しうる (分岐点 約 44 step)。

**言えない。**

- 「colocated は本質的に 5 倍遅い」。B300 の 5.1 倍は **slime** で測った値である。
  同じ H200 で slime (0.88-0.90s) と miles (0.48s) に約 1.8 倍の差があるので、
  5.1 倍の相当部分がフレームワーク由来の可能性がある。**B300 で miles を測らない限り
  分解できない。**
- 「2.84 倍が転送方式の差である」。上記の通り colocated 側だけが pause/flush を含む。
  正しくは「配置 (placement) を変えたときの weight sync 総コストの差」である。
- `ipc_collect()` が主犯という帰属。コードリーディングによる仮説であり、
  **プロファイラ (nsys) で検証していない。**

## 測っていないこと (この実験の限界)

1. `flush_cache` 単独の費用。非対称の主要因かどうか未確定。
2. **GPU 効率での正規化。** disaggregated は GPU を 2 倍使う。sync が 0.3 秒速くても
   コスト当たりで有利とは限らない。
3. step 全体に対する寄与率。この構成では 1 step が 100 秒規模なので、
   0.3 秒の差は 0.3% 程度にすぎない。**登壇でこの数字を出すときは寄与率も併記すべき。**
4. モデルサイズ依存性。4B の重みは小さく、30B/70B で倍率が保存する保証はない。
5. engine 数スケーリング。CUDA IPC は engine 数に線形、NCCL broadcast は log 的のはず。
6. H200 での slime 再測定。既存の slime 値は別クラスタ・別日で、起動ログが残っていない。
7. TP8 の disaggregated を mem-fraction 0.8 で測っていない (`p3d_*` は 0.85)。

## 再現方法

```bash
# セル生成 (comparisons が「placement だけが違う」ことを生成時に検証する)
cd experiment && python3 lib/gen_cells.py specs/p3m_method_matrix.json --outdir <outdir>

# 実行 (RECIPE は disaggregated に対応した版を指す)
RUN_DIR=<dir> RECIPE=recipe/run_grpo_qwen3_4b.sh EXP_ROOT=/fsx/exp EXP_NAME=p3m_matrix \
  bash run_batch.sh env_p3m_colo_tp1_mf08 env_p3m_disagg_tp1_mf08 env_p3m_disagg_tp1_mf085

# 集計と定常判定 (verdict != STEADY なら非ゼロ終了)
python3 collect_weight_sync.py \
  colo_mf08=/fsx/tb/p3m_colo_tp1_mf08 \
  disagg_mf08=/fsx/tb/p3m_disagg_tp1_mf08 \
  disagg_mf085=/fsx/tb/p3m_disagg_tp1_mf085
```

ガードの回帰テストは `python3 test_placement_guards.py` (14 チェック)。
Python 側 (生成時の設計検証) と bash 側 (実行時の入力検証) に同一の不正入力を食わせ、
両方が拒否することを固定している。
