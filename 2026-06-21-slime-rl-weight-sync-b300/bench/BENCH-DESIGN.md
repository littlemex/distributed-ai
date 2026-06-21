# Weight Sync apple-to-apple ベンチ設計

**目的**: SLIME の weight sync を **方式 × モデル規模** の2軸で、**他条件を揃えた対照実験**として測り直し、登壇で使える apple-to-apple 比較を得る。

## なぜ測り直すか (既存測定の問題)

初期の3測定 (`env_vars.akazawt` / `env_vars.disagg-4b` / `env_vars.disagg-30b`) は、
方式やモデルを変えるときに **engine 数・mem-fraction も同時に動いていた**ため、
「方式の差」を主張するには交絡が大きすぎた。

| 初期測定 | モデル | 方式 | engine | mem-frac | weight sync |
| --- | --- | --- | --- | --- | --- |
| 旧① | 4B | colocated | 2 (TP8×2) | 0.4 | ~1.2s |
| 旧② | 4B | disaggregated | 4 (TP2×4) | 0.8 | ~0.3s |
| 旧③ | 30B-MoE | disaggregated | 3 (TP2×3) | 0.8 | ~10s |

- 旧①vs② (方式比較): engine数 (2 vs 4) と mem-fraction (0.4 vs 0.8) がズレ → **apple-to-apple でない**
- 旧②vs③ (規模比較): TP/EP/engine 全部違う → **比較不可**
- 旧③は比較の相方がおらず **浮いていた**

**ただし初期測定は無駄ではない**: 壁の対処 (TE/log_level/gloo/numpy/mbridge/MoE backend)、
MoE root cause (flashinfer_trtllm swizzled 非互換)、各構成の絶対値は全て本ベンチの土台。
本ベンチは「数値だけ apple-to-apple に取り直す」もので、知見は全て引き継ぐ。

## ベンチマトリクス (3セル)

| セル | モデル | 方式 | engine | mem-frac | 役割 |
| --- | --- | --- | --- | --- | --- |
| **A1** | Qwen3-4B | colocated (CUDA IPC) | 4 | 共通 | 方式比較の colocated 側 |
| **A2** | Qwen3-4B | disaggregated (NCCL/EFA) | 4 | 共通 | 方式比較の disagg 側 / 規模比較の小 |
| **B1** | Qwen3-30B-A3B MoE | disaggregated (NCCL/EFA) | 4 | 共通 | 規模比較の大 |

### 何を揃え、何を変えるか (apple-to-apple の核)
- **A1 ↔ A2 (方式軸)**: モデル(4B)・engine数(4)・mem-fraction・訓練ハイパラを固定。
  **変えるのは方式 (COLOCATE) だけ** → CUDA IPC vs NCCL/EFA の純粋比較。
- **A2 ↔ B1 (規模軸)**: 方式(disaggregated)・engine数(4)・mem-fraction を固定。
  **変えるのはモデル規模 (4B → 30B MoE) だけ** → weight sync の転送量スケーリング。

### 揃えるための工夫
- **engine 数 = 4 を全セル共通に**: A1 は `ROLLOUT_GPUS_PER_ENGINE=4` (16/4=4, TP4)、
  A2/B1 は `ROLLOUT_GPUS_PER_ENGINE=2` (8/2=4, TP2)。旧①が 2 engine だったのを 4 に揃える。
- **mem-fraction を共通値に**: `BENCH_MEM_FRACTION` (既定 0.5) を 3 セルに外部注入。
  - 制約: colocated (A1) は train と GPU 共有のため高すぎると OOM (旧① 0.8 で OOM → 0.4)。
    disaggregated は rollout 専有なので本来 0.8 可。**両者で取れる共通値を 0.5 から探る**。
  - **手順**: まず A1 を 0.5 で投入 → OOM しなければ 0.5 で 3 セル確定。OOM したら
    `BENCH_MEM_FRACTION=0.4` 等に下げて全セル再投入 (3 セルとも同じ値で揃えるのが鉄則)。
- **NUM_ROLLOUT=10 / SAVE_INTERVAL=1000**: weight sync を数回観測できれば十分。保存はしない。

## GPU が空いたら実行する手順

```sh
cd .../reference-test/bench

# (1) mem-fraction 共通値を決める: まず colocated を 0.5 で試す
BENCH_MEM_FRACTION=0.5 ./run_bench.sh A1
#   → ログで OOM が出ないか確認 (collect_bench.sh A1)。OOM なら 0.4 に下げて再試行。

# (2) 共通値が決まったら 3 セルを同じ mem-fraction で投入
BENCH_MEM_FRACTION=<決めた値> ./run_bench.sh A1 A2 B1
#   (順次投入。各セルはモデルロード+capture で 4B 数分 / 30B ~10分)

# (3) 集計
./collect_bench.sh
#   → 各セルの weight sync 値 + engine数/mem-fraction/400error を表示。
#     apple-to-apple チェックリストで前提 (engine数・mem-fraction 一致) を確認。
```

## 期待する成果物 (登壇用)

```
| モデル | 方式 | weight sync (定常) | 備考 |
| 4B    | colocated (CUDA IPC)   | A1 実測 | 方式比較 ↕ |
| 4B    | disaggregated (NCCL)   | A2 実測 | 方式比較 ↕ / 規模比較 ↔ |
| 30B   | disaggregated (NCCL)   | B1 実測 | 規模比較 ↔ |
（全セル engine数=4, mem-fraction 共通 → apple-to-apple）
```

これで「方式で何倍 / 規模で何倍」を**交絡なく**言える。旧測定の「engine数や mem-fraction も
違うので方式の差と言い切れない」という弱点が解消される。

## 注意 / リスク
- A1 (colocated, engine4/TP4) は旧① (engine2/TP8) と構成が違うため、4B colocated を
  TP4 で動かせるか初回確認が要る (Qwen3-4B は TP4 可能なはず)。
- B1 (30B engine4) は旧③ (engine3) より rollout GPU を 1 増やす。actor 7+rollout 8+driver 1=16。
  GPU メモリが厳しければ engine 数を 3 に戻し A2 側も 3 に揃える案もある (engine 数を揃えることが優先)。
- mem-fraction 共通値で colocated が OOM する場合、PYTORCH_CUDA_ALLOC_CONF=expandable_segments で
  緩和済みだが、それでもダメなら「両セルで取れる最大の共通値」まで下げる。

---

## 実測結果 (2026-06-21 実施・確定)

3 セルとも mem-fraction 0.5・engine 数 4 で完走 (OOM なし)。一次データは
`/fsx/akazawt/slime/logs/bench_{A1,A2,B1}_*.log` の `Timer update_weights end`。

| セル | モデル | 方式 | engine (構成) | mem-frac | 初回 | **定常** |
| --- | --- | --- | --- | --- | --- | --- |
| A1 | Qwen3-4B | colocated (CUDA IPC) | 4 (TP4×4, 16/4) | 0.5 | 2.6s | **~1.5s** (1.6/1.5/1.4) |
| A2 | Qwen3-4B | disaggregated (NCCL/EFA) | 4 (TP2×4, 8/2) | 0.5 | 3.0s | **~0.3s** (0.3/0.3) |
| B1 | Qwen3-30B-A3B MoE | disaggregated (NCCL/EFA) | 4 (TP2×4, 8/2) | 0.5 | 13.1s | **~10.1s** |

- **方式軸 (A1↔A2)**: disaggregated が colocated の **約 5 倍速い** (定常 0.3s vs 1.5s)。
  engine 数・mem-fraction を揃えても初期測定 (約 4 倍) と同傾向 → 差の主因は転送メカニズム。
- **規模軸 (A2↔B1)**: 30B MoE は 4B の **約 34 倍** (定常 10.1s vs 0.3s)。weight sync は転送量依存。

### 設定値の検証 (apple-to-apple 前提が成立したことの裏取り)
投入ログの grep で確認済み:
- A1: `Colocated: true`, `rollout-num-gpus-per-engine 4`, `sglang-mem-fraction-static 0.5`
- A2: `Colocated: false`, `rollout-num-gpus-per-engine 2`, `sglang-mem-fraction-static 0.5`
- B1: `Colocated: false`, `rollout-num-gpus-per-engine 2`, `sglang-mem-fraction-static 0.5`, `moe-runner-backend triton`
- engine 数は A2/B1 とも `Ports for engine 0..3` = 4 を確認、A1 は 16/4=4。

### 実施中に踏んだ B1 の Megatron 制約 (env.B1 のコメントにも記載)
30B (TP2) で actor GPU 数を決める際、2 つの assertion を同時に満たす必要があった:
1. `world_size % total_model_size(TP2×PP1×CP1=2) == 0` → actor は偶数
2. `global_batch_size(128) % (micro_batch(1) × DP) == 0` → DP が 128 の約数
   - actor 7 (当初案): (1) NG (7%2!=0)
   - actor 6: (1) OK だが DP3 で (2) NG (128%3!=0)
   - **actor 4 (DP2×TP2): (1)(2) とも OK** → これを採用 (actor4+driver1+rollout8=13 GPU)
A2(4B) は actor 8 (DP8×TP1) で両制約 OK だった。actor GPU 数が A2/B1 で異なるが、
weight sync の転送先 (rollout engine 数=4) は揃っているので apple-to-apple は保たれる。
