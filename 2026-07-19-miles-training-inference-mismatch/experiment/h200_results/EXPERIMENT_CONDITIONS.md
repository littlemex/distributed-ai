# 実験条件の完全記録

> 登壇チームへの引き継ぎ資料。各 Finding の実行条件を env ファイルから確定した。
> 条件の差分は `EXTRA_TRAIN_ARGS` の末尾フラグだけであり、genuine な single-variable diff。

## 共通条件 (全 Finding で同一)

| 項目 | 値 |
|---|---|
| Framework | miles (SGLang 0.5.16 rollout + Megatron-LM trainer + Ray orchestration) |
| Container image | `miles-dev202607182122-efa1.48` (radixark/miles + AWS EFA layer) |
| Model | Qwen/Qwen3-4B (dense, 4B params) ※30B は別記 |
| Weight precision | bf16 |
| Dropout | 0 (attention + hidden) |
| Seed | 1234 (rollout-seed 42) |
| Colocated | true (CUDA IPC weight sync) ※disaggregated arm は別記 |
| TP/PP/CP/EP | 1/1/1/1 ※別記のものを除く |
| Batch | 16 prompts x 8 samples = 128 tokens/step |
| Data | DAPO-Math-17k (train), AIME-2024 (eval) |
| Reward | deepscaler |
| Rollout temperature | 1.0 |
| TIS config | `mis_metrics_only.yaml` (TIS disabled, measurement only) ※TIS arm は別記 |
| Orchestration | Amazon EKS + KubeRay, FSx for Lustre at /fsx |

## Finding #1: Per-kernel attribution (6 構成 OFAT)

**GPU: H100 x8 (p5.48xlarge), single node**
**LR: 1e-6 (全 6 arm で統一)**
**Steps: 1 (step 0 のみ、optimizer 更新なし)**

| Cell | 唯一の差分 (EXTRA_TRAIN_ARGS 末尾) | mis_kl | 解釈 |
|---|---|---|---|
| `e4_c0_auto` | (なし) | 0.000716 | bf16 baseline |
| `e4_c1_kv_e5m2` | `--sglang-kv-cache-dtype fp8_e5m2` | 0.0324 | 45x 増幅 |
| `e4_c2_kv_e4m3` | `--sglang-kv-cache-dtype fp8_e4m3` | 0.00865 | 12x 増幅 |
| `e4_c3_kv5_triton` | `--sglang-kv-cache-dtype fp8_e5m2 --sglang-attention-backend triton` | 0.0319 | fp8+triton = fp8 のみと同等 |
| `e4_c4_nocudagraph` | `--sglang-disable-cuda-graph` | 0.000671 | cuda graph 無関係 |
| `e4_c5_triton_only` | `--sglang-attention-backend triton` | 0.000663 | triton attention 無関係 |

### Apple-to-apple の証明

1. **LR は全 arm で 1e-6** — env ファイルで確認済み。LR 交絡なし。
2. **Step 0 のみ** — optimizer.step() が走っていないので重みは全 arm で同一 (init weights)。
3. **Image/model/seed/batch/dropout 全て同一** — 差分は SGLang の runtime flag のみ。
4. **最強の control pair**: `e4_c3_kv5_triton` (fp8 + triton) vs `e4_c5_triton_only` (bf16 + triton)。同じ triton kernel で dtype だけ変えても 0.0319 vs 0.000663 = **48x**。カーネル実装の交絡を排除。

### 残る限界 (登壇で正直に言うこと)

- 各 arm seed 1 本 (run-to-run 分散は未測定。ただし baseline のばらつきが ±20% でも 45x は有意)
- fp8 有効化が SGLang のメモリスケジューリング (KV pool サイズ) を変える可能性 → 検証していない
- 生成トークン列が arm ごとに分岐する (teacher-forcing 評価はしていない)

## Finding #2: 3-seed collapse/rescue (30 step)

**GPU: H100 x8 (p5.48xlarge), single node**
**LR: 1e-5** (崩壊を起こすために高い LR を使用)
**Steps: 30**
**Seeds: 1234, 42, 123**

| Arm | TIS config | 結果 |
|---|---|---|
| `amplified_s{1234,42,123}` | `mis_metrics_only.yaml` (TIS off) | **全 3 seed 崩壊** (mis_kl 5.48 ± 4.95 at step 24) |
| `tis_s{1234,42,123}` | `mis.yaml` (TIS on, upper_bound=2.0) | **全 3 seed 収束** (mis_kl 0.118 ± 0.025 at step 24) |

追加の差分: `--sglang-kv-cache-dtype fp8_e5m2` (崩壊を誘発するため fp8)

### #1 との条件差

| | #1 (per-kernel) | #2 (3-seed) |
|---|---|---|
| LR | **1e-6** | **1e-5** |
| Steps | 1 | 30 |
| KV cache | arm ごとに変える | fp8_e5m2 固定 |
| TIS | off | on/off が変数 |

**#1 と #2 の mis_kl 値を直接比較してはいけない** (LR が違う)。#1 は帰属、#2 は崩壊/救済の再現性が目的。

## Finding #3: Weight sync comparison

**GPU: H200 x8 (p5en.48xlarge), single node**
**LR: 1e-6**
**Steps: 7** (warmup 3 を捨て、残り 4 で定常判定)
**KV cache: bf16 (auto)**

| Arm | Weight sync 方式 | `--colocate` | mem_fraction_static | 定常 median |
|---|---|---|---|---|
| `p3m_colo_tp1_mf08` | colocated (CUDA IPC + flush_cache) | true | 0.8 | **0.482s** |
| `p3m_disagg_tp1_mf08` | disaggregated (NCCL broadcast, intra-node NVLink) | false | 0.8 | **0.170s** |

### Apple-to-apple の証明

1. **mem_fraction_static を 0.8 に揃えた** — SGLang の KV pool サイズを統一。
2. **LR/model/batch/seed 全て同一** — 差分は `--colocate` flag のみ。
3. **定常判定が通っている** (CV <= 5%, drift <= 10%, n >= 4)。

### 注意

- colocated の 0.482s には `pause_generation` + `flush_cache` が含まれる。
- 「転送方式の差」ではなく「配置を変えたときの**総コスト差**」。
- TP=1 の 1 構成のみ。TP を変えると値は変わる (TP8 は未完走)。

## Finding #4: Fork concordance

**GPU: H200 x8 (or x16), p5en.48xlarge**
**LR: 1e-6**
**KV cache: bf16**

### 4B (single node)

| Run | Framework | mis_kl | Steps | 出所 |
|---|---|---|---|---|
| `miles-smoke` | miles | 0.000632 | 1 | 7月 FSx |
| `smoke` | 非miles計装 (推定 slime) | 0.000597 | 3 (last value) | 7月 FSx |

差: 5.7% (大きい側分母)

### 30B MoE (2 nodes, 16 GPU, TP4/EP2)

| Run | Framework | mis_kl | Steps | 出所 |
|---|---|---|---|---|
| `miles-2node-30b` | miles | 0.001922 | 1 | 7月 FSx |
| `slime-30bc-clean` | slime | 0.001820 | 1 | 7月 FSx |

差: 5.3% (大きい側分母)。両方 repetition=0, reward>0.5 で健全。

## FAQ (登壇で聞かれそうな質問への回答)

### Q: LR が fp8 arm と baseline で違うのでは？
A: **per-kernel 実験では全 arm LR=1e-6 で統一**。env ファイルで確認済み。3-seed 実験は LR=1e-5 だが、これは崩壊を起こすための条件設定であり、比較対象は同じ LR の TIS on/off。

### Q: step 0 なら LR は関係ないと言えるのか？
A: はい。mis_kl は重みの関数で、LR は optimizer.step() で初めて重みに作用する。step 0 = 更新前なので、LR の値に関わらず重みは全 arm で init weights のまま。実装上も、mis_kl の計算は forward 直後・backward 前 (losses.py L206) で行われる。

### Q: seed 1 本で 45x と言えるのか？
A: 有効桁 1 桁の点推定。正確には「おおよそ 50 倍のオーダー」。baseline のばらつき (±20%) を最大限に効かせても 32x は残り、有意。

### Q: カーネル実装の交絡は？
A: `e4_c3_kv5_triton` (fp8+triton) vs `e4_c5_triton_only` (bf16+triton) が control pair。同じ triton kernel で dtype だけ変えて 48x。カーネル実装は無関係。

### Q: H100 と H200 のデータを混ぜていないか？
A: per-kernel (#1) と 3-seed (#2) は H100。weight sync (#3) と concordance (#4) は H200。H100/H200 間で mis_kl に有意差はない (5.4%, baseline ばらつき以下)。ただし値の大小の直接比較は避け、方向のみ参照。
