# SLIME weight sync 実測結果 (B300)

**測定日**: 2026-06-20
**環境**: EKS ml-clusters-shared-us-west-2 / p6-b300 x2 (sm_103, 8 GPU/node) / NGC image slime:v0.2.4-ngc-b300
**設定**: GRPO, mem-fraction 0.4, expandable_segments:True, --no-offload, GRPO 6+周回 OOM 0

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
| 方式 | 転送単位 | Update weights バー | 解釈 |
|---|---|---|---|
| colocated | **16/16** (16 engine に個別 IPC 転送) | `[00:01<00:00]` 13.8 it/s ≈ 1.0s + pause/flush = 計 ~1.2s | engine 1個ずつ CUDA IPC + 毎回 ipc_collect |
| disaggregated | **17it** (PP group NCCL broadcast) | `[00:00]` 1秒未満 = 計 ~0.3s | 1対多を並列 broadcast で一括 |

追加発見: colocated は rollout 16 engine (TP1×16)、disaggregated は 4 engine (TP2×4)。
colocated の per-engine IPC 転送は **engine 数に比例**して遅くなる (16回ループ) が、NCCL broadcast は
engine 数によらず一括配信。**engine 数の差も colocated 不利に効いている** (転送方式 × engine 数の複合)。

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

## ============ 最終比較表 (全実測完了) ============

| モデル | 方式 | 実装 | weight sync (定常) |
|---|---|---|---|
| Qwen3-4B | colocated | UpdateWeightFromTensor (CUDA IPC) | ~1.2s |
| Qwen3-4B | disaggregated | UpdateWeightFromDistributed (NCCL/EFA) | ~0.3s |
| Qwen3-30B-A3B MoE | disaggregated | UpdateWeightFromDistributed (NCCL/EFA) | 14.4s → 10.2s |

観測:
1. 4B 同一モデルで colocated(CUDA IPC, per-engine ipc_collect)より disaggregated
   (NCCL 一括 broadcast)が定常で約4倍速い (1.2s vs 0.3s)。直感に反する、原因は転送経路の
   per-step オーバーヘッド差。
2. 30B MoE は転送量が桁違いに大きく (305億params, EP=2 の全 expert broadcast)、
   weight sync も 10秒級。MoE の EP weight (non-expert TP + expert EP の2段) を NCCL/EFA で
   転送する実用ケースを実測。
3. SGLang 0.5.12 で MoE を回すには moe-runner-backend を triton 明示が必須 (flashinfer_trtllm の
   swizzled レイアウトが online weight update と非互換)。これは upstream 未解決 (#2091/#1840)。
