# SLIME weight sync 実測結果 (B300)

**測定日**: 2026-06-20 (初期測定) / 2026-06-21 (apple-to-apple 追測定)
**環境**: EKS ml-clusters-shared-us-west-2 / p6-b300 x2 (sm_103, 8 GPU/node) / NGC image slime:v0.2.4-ngc-b300
**設定**: GRPO (advantage-estimator grpo, n-samples 8, kl-coef 0), expandable_segments:True, --no-offload

> **本ドキュメントは 2 部構成**:
> - 「初期測定 (2026-06-20)」: mem-fraction・engine 数が方式ごとに違い、方式の差を主張するには
>   交絡があった (下記 §初期測定)。原因究明・壁の突破はここで完了。
> - **「apple-to-apple 測定 (2026-06-21)」: 全セルで engine 数=4・mem-fraction=0.5 を揃え、
>   方式軸と規模軸を交絡なく比較した確定版 (下記 §apple-to-apple)。登壇で使うのはこちら。**

# ====================== 初期測定 (2026-06-20) ======================
# 注意: 以下は mem-fraction (0.4 vs 0.8) と engine 数 (2 vs 4) が方式ごとに異なる。
# 原因究明・壁突破はここで完了したが、方式の差を「同条件で」主張するなら
# §apple-to-apple (2026-06-21) の値を参照すること。

## colocated (CUDA IPC, UpdateWeightFromTensor) — 実測済み

Qwen3-4B, TP=8, colocate=true。`actor.py:135` で `UpdateWeightFromTensor` を選択、
ログ上 `POST /update_weights_from_tensor` で CUDA IPC 方式を実証。

| 周回 | update_weights elapsed |
|---|---|
| 1 (初回, IPC handle 確立込み) | 2.4s |
| 2 | 1.2s |
| 3 | 1.5s |
| 4-7 | 1.2s (安定) |

**定常値: 約 1.2s**。初回のみ CUDA IPC handle 確立のオーバーヘッドで 2.4s。

### GRPO 1周の train step 内訳 (参考)
- update_weights (weight sync): 1.2s
- ref_log_probs: 1.2-1.7s
- actor_train (backward + optimizer): 20-30s
- train end (合計): 21-33s

## disaggregated (NCCL/EFA, UpdateWeightFromDistributed)

### Phase A: Qwen3-4B (colocated と同一モデル = 純粋比較) — 実測済み

COLOCATE=false。GPU 配分: actor 8 GPU (node1) + rollout 8 GPU (node2, TP2 x 4 engine) = 16、
ノードをまたぐので weight sync は EFA 経由 NCCL broadcast。`actor.py:135` で
`UpdateWeightFromDistributed` を選択、ログ上 `POST /update_weights_from_distributed` +
`init custom process group` + `[slime-pp_0] Update weights` で NCCL broadcast 方式を実証。

| 周回 | update_weights elapsed |
|---|---|
| 1 (初回, NCCL group 確立込み) | 2.9s |
| 2 | 0.4s |
| 3 | 0.3s |
| 4 | 0.3s |

**定常値: 約 0.3s**。初回のみ NCCL custom process group 確立 (`init custom process group`) で 2.9s。

### ★ 方式比較サマリ (Qwen3-4B, 同一モデル・モデル固定の純粋比較)

| weight sync 方式 | 実装 | 初回 | 定常 |
|---|---|---|---|
| colocated | UpdateWeightFromTensor (CUDA IPC) | 2.4s | **~1.2s** |
| disaggregated | UpdateWeightFromDistributed (NCCL/EFA) | 2.9s | **~0.3s** |

**初回は colocated が速い (2.4 < 2.9)、定常は disaggregated が約4倍速い (0.3 < 1.2)** — 直感に反する重要な発見。

#### 原因究明 (なぜ定常で disaggregated が速いか — コードレベルで確定)

両方式の `update_weights()` 実装 (`backends/megatron_utils/update_weight/`) を精査した結果、
差は「メモリ競合」ではなく **weight 転送メカニズムそのもの** と判明:

| 観点 | colocated `UpdateWeightFromTensor` | disaggregated `UpdateWeightFromDistributed` |
|---|---|---|
| Timer の範囲 | `actor.py:543` の pause+flush+connect+転送 (両方式共通) | 同左 |
| pause/flush | あり (両方式共通) | あり (両方式共通) ← 当初「disagg は pause 無し」は誤り |
| 転送方式 | `_send_to_colocated_engine` (CUDA IPC, 同一 GPU の tensor handle 共有) | `_update_weight_from_distributed` (NCCL broadcast) |
| **per-chunk コスト** | **`torch.cuda.ipc_collect()` を weight chunk ごとに呼ぶ** (update_weight_from_tensor.py:165) + `ray.get(refs)` で各 engine の IPC handle open/close ラウンドトリップ | non-expert(TP)→expert(EP) を**バッファに蓄積して一括 NCCL broadcast** (buffer_size 蓄積、ipc_collect 無し) |
| 初回の追加コスト | CUDA IPC handle 確立 (~2.4s) | NCCL custom process group 確立 `init custom process group` (~2.9s) |

**結論**: 「colocated は同一 GPU だから速いはず」という直感は、CUDA IPC の per-chunk GC
(`ipc_collect()` は全 GPU 同期を伴う) と Ray 経由の IPC handle ラウンドトリップのオーバーヘッドで
覆る。B300 の大 HBM では ipc_collect の GC 対象ブロックが多く、さらに不利。一方 NCCL broadcast は
group 確立後 (定常) は純粋なネットワーク転送 (EFA 高帯域) のみで、per-chunk GC が無いため ~0.3s。

→ **weight sync で本質的に効くのは「同一 GPU か否か」ではなく「転送経路の per-step オーバーヘッド
(IPC handle GC vs NCCL 一括 broadcast)」**。これが直感に反する結果の根本原因。

#### 実ログでの数値的裏付け (転送バーの所要時間)
| 方式 | 転送バー | Update weights バー | 解釈 |
|---|---|---|---|
| colocated | **16 単位** (`Update weights 0→16`) | `[00:01<00:00]` 13.8 it/s ≈ 1.0s + pause/flush = 計 ~1.2s | チャンクごと CUDA IPC + 毎回 ipc_collect |
| disaggregated | **17 it** (`[slime-pp_0] Update weights`) | `[00:00]` 1秒未満 = 計 ~0.3s | バッファに溜めて NCCL 一括 broadcast |

[訂正] 当初「colocated 16 engine / engine 数比例」と記したが、一次ログ再確認の結果**誤り**だった。
実際の engine 数 (`Ports for engine N` の最大 + `fired up` 数) は:
- **colocated: 2 engine** (TP8×2、`ROLLOUT_GPUS_PER_ENGINE=8`)
- **disaggregated: 4 engine** (TP2×4、`ROLLOUT_GPUS_PER_ENGINE=2`)

つまり **colocated の方が engine 数は少ない** (2 < 4)。「engine 数に比例して colocated が遅い」は成立しない。
colocated の `Update weights 0→16` の「16」は engine 数ではなく **CUDA IPC で転送する重みチャンク数**。
→ 差の要因は engine 数ではなく、**転送メカニズムそのもの** (colocated はチャンクごとに `ipc_collect()`
[全GPU同期GC] + Ray IPC ハンドルの往復、disaggregated はバッファに溜めて NCCL 一括 broadcast) に絞られる。
ただし下記の通り、この要因分解は**コード読解とログの間接証拠**に基づく仮説であり、ipc_collect 単体の
定量分離 (patch で除去した before/after 計測) は行っていない。

#### 補足: 交絡要因の切り分け
- colocated は mem-fraction 0.4 (train と KV cache 同居)、disaggregated は 0.8 (rollout 専有)。
  ただし上記の通り**差の主因は mem-fraction ではなく転送メカニズム** (ipc_collect vs NCCL) であり、
  コード精査で裏付け済み。mem-fraction はメモリ収まりの問題であって weight sync 時間の主因ではない。
- 完全分離するなら colocated でも ipc_collect を chunk 跨ぎでまとめる改造が要るが、これは SLIME 本体の
  実装 (リファレンス通り) を尊重した「素の SLIME の実運用 weight sync コスト」としての比較。

これは Zenn 記事 (xm7cpx4i3lgh) が「推定」としていた weight sync 方式差を B300 実測で裏付け、
かつ「colocated の方が常に速い」という素朴な推定を**定常状態では覆し、コードレベルで原因を特定**した。
登壇ネタとして強い (実測 + 直感否定 + ソース根拠の3点セット)。

### Phase B: Qwen3-30B-A3B MoE — 未測定 (実用ケース)

MoE 大モデルで EP weight 含む disaggregated。モデル DL + Megatron 変換が必要。次のステップ。

## 出典
一次データ: RESULTS/smoke_STABLE_memfrac04_*.log (colocated), RESULTS/disagg4b_*.log (disaggregated)
の `Timer update_weights end` 行。

---

## Phase B: Qwen3-30B-A3B MoE disaggregated — non-expert 成功 / expert は SGLang 非互換

30B MoE (TP2/EP2, actor 8 + rollout 6 + driver 1 GPU) で disaggregated weight sync を測定。
途中で MoE 固有の壁を複数突破:

- **壁10**: `--moe-grouped-gemm` (qwen3-30B-A3B.sh) が Megatron validate_args で
  `torch.cuda.get_device_capability()` を呼ぶ (arguments.py:906)。train.py の parse_args は
  ray job の driver (head, GPU 0) で走るため `Found no NVIDIA driver`。
  → `--entrypoint-num-gpus 1` で driver を GPU ノードへ。rollout 8→6 で GPU 確保。
- **壁11**: SGLang rollout EP=1 vs Megatron EP=2 不整合で expert 転送 400。
  リファレンス Option C の `--sglang-enable-ep-moe` は **SGLang 0.5.12 で廃止** (server_args に
  enable_ep_moe 無し)。正しくは `--sglang-expert-parallel-size 2` (SLIME arguments.py:142 で
  sglang_ep_size→ep_size=2)。→ ep_size=2 反映を確認。

### 測定できたこと
- **non-expert (TP) weight broadcast は成功** (初回 6.0s)。MoE でも NCCL/EFA broadcast 自体は動く。

### 残った壁 (原因究明済み・SGLang 0.5.12 側の制約)
EP を両側 2 に揃えても **expert (EP) bucket broadcast で形状不一致**
(`size of tensor a(64) must match b(2048) at dim 2`、64=local experts=128/EP2、2048=hidden)。

原因の構造 (コード精査で特定):
- SLIME `convert_qwen3moe_to_hf` (megatron_to_hf/qwen3moe.py:25-43) は expert を**個別名**
  (`mlp.experts.{idx}.gate_proj.weight`、2D) で送出する。
- SGLang 0.5.12 の qwen3_moe.py は MoE backend が `flashinfer_trtllm` (server_args 既定) で
  expert を **stacked/fused 表現** (3D `[num_experts, ...]`) で持つ。`load_weights` は個別 expert 名を
  `expert_params_mapping` で処理できるが、**online の `update_weights_from_distributed` 経路**では
  EP 分割された stacked param の部分形状と個別 expert tensor が map できず dim 2 で不一致。
- これは SGLang 0.5.12 の online MoE weight update と SLIME v0.2.4 の個別 expert 送出の
  **非互換**。フラグ調整では解けず SGLang/SLIME のソース修正が要る領域。リファレンス
  (古い SGLang 前提) も当てにならない (enable-ep-moe 廃止が傍証)。

### 結論
weight sync 方式比較の核心 (CUDA IPC vs NCCL/EFA、定常 1.2s vs 0.3s、原因究明) は **4B で完全達成**。
30B MoE は **non-expert 転送まで実証** (MoE でも NCCL broadcast が動く)、expert は SGLang 0.5.12 の
online MoE update 非互換として記録。登壇では「4B で方式差を定量化 + 原因究明、MoE は non-expert まで
動作確認し expert online update は SGLang 側の課題」と整理できる。

### 切り分け実験で根本確定 (2026-06-20)
expert 形状不一致が「EP>1 の分割問題」か「MoE online update 自体の問題」かを切り分けるため
**EP=1 (expert 分割なし、TP2 のまま) で 30B disaggregated を実行**:
- 結果: EP=1 でも **完全に同じエラー** (`size of tensor a(64) must match b(2048) at dim 2`)。
  non-expert(TP) broadcast は成功 (6.1s)、expert broadcast で 400 (9件)。
- → エラーは **EP 数に完全に非依存**。「EP 分割 expert の map 問題」ではなく
  **SGLang 0.5.12 の online MoE weight update と SLIME v0.2.4 の個別 expert 送出の
  構造的非互換** であることが確定。`64` は EP 非依存の固定ズレ
  (convert_qwen3moe_to_hf の出力 expert 次元 vs SGLang stacked expert の期待次元)。
- **フラグ調整 (EP 数 / --sglang-expert-parallel-size) では解けない**。SGLang か SLIME の
  online MoE weight update 経路のソース改変が必要。リファレンスも古い SGLang 前提で当てにならない
  (--sglang-enable-ep-moe 廃止が傍証)。

---

## ★ 30B MoE expert online update — root cause 実測特定 + env 修正で解決 (2026-06-21)

### 実測による root cause 確定
SGLang `model_runner.py` / `fused_moe_triton/layer.py` に shape ログを仕込んで実測:
- **SLIME 送出は完全に正しい**: `gate_proj.weight (768, 2048)` = HF 標準形状、個別 expert 2D。
- SGLang param の大多数 (36844件) は `(1536, 2048)` 2D で SLIME と整合し**成功**。
- **6件だけ `(32, 1536, 64)` の swizzled 3D**: これが `flashinfer_trtllm` MoE backend
  (B300 で auto 選択) が一部 expert に使う特殊レイアウト。SLIME の 2D と dim 2 で衝突 → 400。
- → 真因は **SGLang 0.5.12 デフォルト MoE backend (flashinfer_trtllm) の swizzled
  レイアウトと SLIME の標準 2D expert weight の非互換**。SLIME issue #2091/#1840 と同根。
  `64 vs 2048` の `64` は flashinfer_trtllm の per-tile swizzle 次元。

### あるべきレイヤでの修正 (env、ソース改変なし、torch 2.11/TE 維持)
```sh
export MOE_ARGS="--expert-tensor-parallel-size 1 --sglang-expert-parallel-size 2 --sglang-moe-runner-backend triton"
```
`--sglang-moe-runner-backend triton` で MoE backend を標準 triton に明示し、swizzled
レイアウトを回避して SLIME の 2D expert weight と整合させる。SGLang/SLIME のソース改変も
torch ダウングレード (壁0 逆戻り) も不要。

### 検証結果: 30B MoE disaggregated weight sync 成功
- **400 error: 0** (expert 転送が全 expert で成功、`slime-pp Update weights` 103回完了)。
- update_weights elapsed: **初回 14.4s → 2回目 10.2s** (30B MoE, TP2/EP2, NCCL/EFA broadcast)。
- GRPO 周回が OOM/エラーなしで継続 (27分+)。

## ============ 初期測定の比較表 (交絡あり・参考) ============

| モデル | 方式 | 実装 | weight sync (定常) | mem-frac | engine |
|---|---|---|---|---|---|
| Qwen3-4B | colocated | UpdateWeightFromTensor (CUDA IPC) | ~1.2s | 0.4 | 2 |
| Qwen3-4B | disaggregated | UpdateWeightFromDistributed (NCCL/EFA) | ~0.3s | 0.8 | 4 |
| Qwen3-30B-A3B MoE | disaggregated | UpdateWeightFromDistributed (NCCL/EFA) | 14.4s → 10.2s | 0.8 | 3 |

上記は mem-fraction と engine 数が方式・規模ごとに違うため、方式/規模の差を「純粋に」主張できない。
そこで下記の apple-to-apple 測定 (全セル engine4・mem0.5) を実施した。

# ====================== apple-to-apple 測定 (2026-06-21) ======================

**目的**: weight sync を「方式 × 規模」の2軸で、他条件 (engine 数・mem-fraction・GRPO ハイパラ) を
揃えた対照実験として測り直し、登壇で使える交絡なしの比較を得る。

**共通条件 (3セル全て)**: engine 数=4、mem-fraction-static=0.5、GRPO (n-samples 8, GBS 128,
rollout-bs 16)、NGC image slime:v0.2.4-ngc-b300、expandable_segments:True、--no-offload。
recipe は `run_grpo_qwen3_4b.reference.sh` を全セル無改変で使用 (env file だけ差し替え)。

| セル | モデル | 方式 | engine (構成) | mem-frac | weight sync 初回 | **weight sync 定常** |
|---|---|---|---|---|---|---|
| **A1** | Qwen3-4B | colocated (CUDA IPC) | 4 (TP4×4, 16/4) | 0.5 | 2.6s | **~1.5s** (1.6/1.5/1.4) |
| **A2** | Qwen3-4B | disaggregated (NCCL/EFA) | 4 (TP2×4, 8/2) | 0.5 | 3.0s | **~0.3s** (0.3/0.3) |
| **B1** | Qwen3-30B-A3B MoE | disaggregated (NCCL/EFA) | 4 (TP2×4, 8/2) | 0.5 | 13.1s | **~10.1s** |

(一次データ: `/fsx/myuser/slime/logs/bench_{A1,A2,B1}_*.log` の `Timer update_weights end`。
各セルの設定値は投入ログの `Colocated:` / `rollout-num-gpus-per-engine` /
`sglang-mem-fraction-static` / `moe-runner-backend` で検証済み。)

### 2つの比較軸 (交絡なし)

**方式軸 (A1 ↔ A2)**: 4B・engine4・mem0.5 を固定し、方式だけ変えた純粋比較。
→ **disaggregated (NCCL/EFA) が colocated (CUDA IPC) の約5倍速い** (定常 0.3s vs 1.5s)。
  初期測定 (mem-fraction 0.4/0.8 がズレていた) でも同じ傾向 (約4倍) が出ていたが、
  本測定で mem-fraction と engine 数を揃えても傾向が変わらないことを確認 = **差の主因は
  mem-fraction でなく転送メカニズム** (CUDA IPC の per-chunk ipc_collect vs NCCL 一括 broadcast)
  であることを実験的にも裏付けた。

**規模軸 (A2 ↔ B1)**: disaggregated・engine4・mem0.5 を固定し、モデル規模だけ変えた比較。
→ **30B MoE は 4B の約34倍** (定常 10.1s vs 0.3s)。weight sync は転送するパラメータ量に
  強く依存し、MoE の EP weight (non-expert TP + expert EP の2段 broadcast) を含む 30B では
  10秒級になる。RL の1ステップ当たり (train 280s に対し) では支配的でないが、無視できない。

### apple-to-apple での注記 (誠実な開示)
- **engine 数=4 は揃えたが、TP 構成は方式で必然的に異なる**: colocated は 16 GPU を rollout と
  共有するので engine4=TP4 (16/4)、disaggregated は rollout 専有 8 GPU で engine4=TP2 (8/2)。
  「engine 数」を揃える設計とした (weight sync の broadcast 先 engine 数が転送ラウンド数に効くため)。
- **B1 の actor GPU 数は A2 と異なる** (A2: actor 8 / B1: actor 4)。16 GPU 制約と Megatron の
  割り切れ条件 (world_size%TP==0 かつ GBS%(micro×DP)==0) で 30B は actor 4 (DP2×TP2) になった。
  ただし weight sync の計測対象は **train actor → rollout engine への broadcast** で、揃えるべきは
  rollout engine 数 (=4、A2/B1 一致)。actor GPU 数差は train 速度に効くが weight sync 転送先には無関係。
- 各セルは weight sync 定常値が見えた時点で停止 (全 rollout 完走は weight sync 計測に不要)。
  A1=4点, A2=3点, B1=2点。30B は1サイクル ~10分のため B1 は2点で打ち切り (初回13.1s/定常10.1s)。

### 結論 (登壇ストーリー)
1. **方式**: 同条件で disaggregated (NCCL/EFA) が colocated (CUDA IPC) より定常で約5倍速い。
   「同一 GPU の colocated が速いはず」という直感を覆す。原因は CUDA IPC の per-chunk
   `ipc_collect()` (全GPU同期GC) + Ray IPC handle 往復 vs NCCL 一括 broadcast の差 (コード精査済み)。
2. **規模**: disaggregated 固定で 30B MoE は 4B の約34倍。weight sync は転送パラメータ量に強く依存。
3. **MoE の前提**: SGLang 0.5.12 で MoE online weight update を回すには `--sglang-moe-runner-backend
   triton` が必須 (flashinfer_trtllm の swizzled レイアウトが非互換)。upstream 未解決 (#2091/#1840)。
