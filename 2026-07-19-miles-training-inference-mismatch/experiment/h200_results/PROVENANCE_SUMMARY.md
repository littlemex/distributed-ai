# 確定データ一覧 (PROVENANCE SUMMARY)

> 登壇資料・blog の数値はこのファイルから引用すること。
> 全 run の帰属は FSx の TensorBoard event file と CloudTrail から機械的に確定した (2026-08-05)。

## ハードウェア

| 期間 | GPU | クラスタ | 確定方法 |
|---|---|---|---|
| 7月 (07-17〜07-21) | **H200 x8** (p5en.48xlarge) | `distai-eks-smoke` | CloudTrail: p5en のみ、H100 は 0 台 |
| 8月前半 (08-02 05:48〜19:51 JST) | **H100 x8** (p5.48xlarge) | `distai-p5-ue2` | CloudTrail: gpu-p5 nodepool |
| 8月後半 (08-02 20:42〜CB終了) | **H200 x8** (p5en.48xlarge) | `distai-p5-ue2` | CloudTrail: gpu-p5en nodepool |

## 確定データ

### 1. Baseline (4B dense, bf16, LR 1e-6, dropout=0, colocated, H200)

| run | mis_kl | abs_diff | 出所 |
|---|---|---|---|
| `miles-smoke` (7月) | **0.000632** | 0.0130 | 7月FSx TB, wall 07-19 14:47 JST |
| `h200_p4_calib` (8月) | **0.000627** | 0.0127 | 8月FSx TB, wall 08-02 21:50 JST |

Run 間ばらつき (8月 3seed): 0.000527-0.000745 (最大/最小 1.41倍)

### 2. KV fp8 増幅 (4B, fp8_e5m2, LR 1e-5, H200)

| run | framework | mis_kl (step 0) | 対 baseline 倍率 |
|---|---|---|---|
| `miles-amp` (7月) | miles | 0.0310 | **49.1x** (対 miles-smoke 0.000632) |
| `E_kvfp8` (7月) | 非miles計装 (推定 slime) | 0.0327 | **54.9x** (対 smoke 0.000597) |

成果物での書き方: **「両 fork とも約 50 倍」**。49x/55x の差は分母の run 間ばらつき (±20%) に埋もれる。LR も同時変化。

### 3. 崩壊アーム (4B, fp8_e5m2, LR 1e-5, no TIS, H200)

| run | mis_kl first → last | steps |
|---|---|---|
| `collapse-amp` (7月, miles) | 0.0329 → **2.097** | 25 |

### 4. 救済アーム (4B, fp8_e5m2, LR 1e-5, TIS, H200)

| run | mis_kl first → last | steps | 備考 |
|---|---|---|---|
| `rescue-tis2` (7月, miles) | 0.0322 → **0.0279** | 30 | 崩壊せず |
| `rescue-tis` (7月, miles) | 0.0328 → 0.0671 | 10 | 打ち切り、上昇途中 (両方併記すること) |

### 5. 3-seed 崩壊/救済 (4B, fp8_e5m2, LR 1e-5, **H100**)

| run | 結果 | mis_kl at step 24 (mean±sd) |
|---|---|---|
| `amplified_s{42,123,1234}` (8月) | **全3seed崩壊** | 5.48 ± 4.95 |
| `tis_s{42,123,1234}` (8月) | **全3seed収束** | 0.118 ± 0.025 |

注意: H100 なので 7月 H200 アームとの値の大小比較は不可。方向 (崩壊 vs 収束) のみ。

### 6. Weight sync (4B, bf16, TP1, H200, STEADY 判定済み)

| run | 方式 | 定常 median | verdict |
|---|---|---|---|
| `p3m_colo_tp1_mf08` | colocated (CUDA IPC + flush_cache) | **0.482s** | STEADY |
| `p3m_disagg_tp1_mf08` | disaggregated (NCCL/EFA) | **0.170s** | STEADY |

比率 2.84x。colocated が遅いのは `pause_generation` + `flush_cache` を含むため。

### 7. 30B MoE apple-to-apple (bf16, 2ノード16GPU, EP2, H200)

| run | framework | mis_kl | repetition | reward |
|---|---|---|---|---|
| `miles-2node-30b` (7月) | miles | **0.001922** | 0.0 | 0.539 |
| `slime-30bc-clean` (7月) | slime | **0.001820** | 0.0 | 0.563 |

差 5.3% (大きい側分母)。両方健全。

### 8. Per-kernel 帰属 (4B, step 0, **H100**)

| run | 構成 | mis_kl |
|---|---|---|
| `e4_c1_kv_e5m2` | KV fp8 e5m2 有効 | **0.0324** |
| `e4_c3_kv5_triton` | KV fp8 e5m2 + triton backend | 0.0319 |
| `e4_c0_auto` | fp8 無効 (auto) | 0.000716 |
| `e4_c4_nocudagraph` | cuda graph 無効 | 0.000671 |
| `e4_c5_triton_only` | triton のみ | 0.000663 |

結論: KV quantization だけが増幅の主因。他 kernel は baseline と同等。

## 限界 (成果物に必ず書くこと)

- 倍率は全て**単一 seed の点推定**。
- Baseline の LR は 1e-6、fp8 アームは 1e-5 で**LR も同時変化**。
- H100 (3-seed, per-kernel) と H200 (崩壊/救済, weight sync) のデータは**値の大小を比較してはいけない**。方向のみ。
- `E_kvfp8` / `smoke` を slime と呼ぶのは推定 (miles 固有タグが無いことからの消去法)。
- Weight sync の colocated は flush_cache を含むので「転送方式の差」ではなく「配置の総コスト差」。
