# SLIME on B300 — リファレンスからの patch 設計

**目的**: awsome-distributed-ai の slime test case (H100/p5 想定) を B300 (sm_103) で動かすために必要な変更を、**アドホックな寄せ集めではなく層別に構造化**し、各 patch の根拠・出典・撤去条件を明示する。

**原則**:
1. **リファレンスからの最小 diff** として表現する。リファレンス本体は改変せず、差分を overlay/patch として分離。
2. 各 patch を **レイヤ**で分類する。本来解くべき層で解き、上の層での回避は「下の層が整うまでの一時対処」と明示。
3. 各 patch に **撤去条件**(いつ不要になるか)を書く。寿命のない patch は作らない。

---

## レイヤモデル

```
┌─────────────────────────────────────────────┐
│ L3: 実行フラグ層 (run_grpo の vllm/megatron flag) │ ← L1/L2 が整えば最小化されるべき
├─────────────────────────────────────────────┤
│ L2: 環境/ランタイム層 (FSx pyenv の patch)        │ ← upstream バグの一時 workaround
├─────────────────────────────────────────────┤
│ L1: イメージ層 (Dockerfile: sm_103, TE, SGLang)   │ ← B300 対応の本丸。ここで解くのが正道
└─────────────────────────────────────────────┘
```

---

## リファレンスの前提 (awsome-distributed-ai slime test case)

| 項目 | リファレンス値 | 出典 |
|---|---|---|
| 対象 GPU | NVIDIA H100 (sm_90) / p5.48xlarge | README |
| base image | `nvcr.io/nvidia/pytorch:26.02-py3` (NGC, **TE 同梱**) | slime.Dockerfile |
| SGLang | 0.5.12.post1 | slime.Dockerfile |
| EFA | 32/node (p5) | raycluster.yaml |
| 主要フラグ | `--colocate --use-dynamic-batch-size --sglang-mem-fraction-static 0.8` | run_grpo_qwen3_4b.sh |

**B300 との差**: sm_103 / EFA 16/node / TE の有無が論点。

---

## L1: イメージ層

### L1-1. sm_103 (Blackwell Ultra) カーネル対応 【必須・本質】
- **問題**: リファレンスの NGC `pytorch:26.02-py3` + SGLang 0.5.12 が sm_103 を完全サポートするか不明。前回は SGLang nightly image (`lmsysorg/sglang:nightly-dev-cu13-...`) に切替えて回避した。
- **正しい解**: リファレンスの Dockerfile を base にしつつ、SGLang/vLLM/flashinfer を sm_103 対応版にビルドする。`TORCH_CUDA_ARCH_LIST` に `10.3` を含める。
- **現状**: 暫定で SGLang nightly image を使用 (`slime:v0.2.4-sgl0.5.13-b300`)。**副作用: この image には TE が無い** → L1-2 / L3 の問題を誘発。
- **撤去条件**: NGC base + sm_103 ビルドの正規 image を用意できれば、nightly image 依存と L3 のフラグ patch 群がまとめて不要になる。← **最も価値ある是正点**

### L1-2. Transformer Engine (TE) の同梱 【L3 の根本原因】
- **問題**: 暫定 image (SGLang nightly) に TE が無い (`Transformer Engine and Apex are not installed`)。リファレンスの NGC base には TE が入っている。
- **影響**: TE 不在のため Megatron が `apply_rope_fusion` / `TESpecProvider` / persist_layer_norm / packed-seq attention を使えず、L3 で多数のフラグ回避が必要になる。
- **正しい解**: image に TE を sm_103 対応でビルド・同梱する。
- **撤去条件**: TE が入れば L3-1〜L3-4 のフラグ patch が**すべて不要**になる見込み (要検証)。

---

## L2: 環境/ランタイム層 (FSx pyenv)

### L2-1. PyTorch MemPool destructor abort workaround 【upstream バグ】
- **問題**: PyTorch 2.11 の `MemPool::~MemPool` が `synchronize_and_free_events` の `captures_underway` assert を発火 (PyTorch issue #175015)。SGLang の CUDA graph backend が graph_pool_handle() を使うため warmup で abort。
- **対処**: `scripts/patch-sglang-mempool.sh` — graph_pool_handle() の返り値をプロセス生存中 keepalive する (3 backend に注入)。
- **レイヤ判断**: これは PyTorch 側のバグであり、フレームワークやフラグの問題ではない。**環境層に隔離**するのが正しい。
- **撤去条件**: PyTorch が PR #175374 (fix) を 2.11.x に backport、または image の torch を fix 込み版にすれば不要。

---

## L3: 実行フラグ層 (run_grpo)

> **重要**: L3 の patch 群は **L1-2 (TE 不在) の派生**である。TE が入れば大半が不要になる。
> 「フラグを10個足す」のではなく「TE 不在という1つの事実への対処」として理解する。

### L3-1. TE 依存フラグの無効化 【L1-2 が直れば不要】
TE 不在時に Megatron が要求するフラグ群:
- `--no-rope-fusion` (apply_rope_fusion は TE 必須)
- `--transformer-impl local` + `--spec local` (TESpecProvider 不在)
- `--attention-backend local`
- `--no-bias-dropout-fusion` / `--no-persist-layer-norm` / `--no-masked-softmax-fusion` / `--no-gradient-accumulation-fusion`
- **撤去条件**: L1-2 (TE 同梱) で一括撤去。

### L3-2. packed-seq 回避 【L1-2 が直れば不要】
- `--qkv-format bshd` + `--micro-batch-size 1` (= `--use-dynamic-batch-size` を外す)
- **理由**: TE 無しの DotProductAttention が packed (thd) seq 非対応。
- **代償**: dynamic batch の効率を失う (性能低下)。
- **撤去条件**: L1-2 で TE が入れば `--use-dynamic-batch-size` + `--qkv-format thd` に戻せる。

### L3-3. weight sync の offload 無効化 【設計判断・撤去不要】
- `--no-offload-rollout --no-offload-train` (`--colocate` と併用)
- **理由**: torch_memory_saver.pause() が KV cache を unmap し Triton kernel が CPU pointer エラー (SGLang issue #5920 と同型)。B300 192GB なら offload 不要。
- **レイヤ判断**: これは B300 の大 HBM を活かす**設計判断**であり、バグ回避ではない。colocated 構成では妥当。
- **撤去条件**: なし (B300 では合理的な定常設定)。ただし disaggregated 構成では別途検討。

### L3-4. SGLang メモリ比率 【調整値】
- `--sglang-mem-fraction-static 0.8 → 0.55` (前回調整)
- **再検証対象**: L3-3 で offload を切ると rollout engine の取り分が変わる。0.8 のままで足りるか B300 で再測定すべき (素フラグ検証の入力)。

---

## 検証ログ (素フラグ実験)

リファレンスの素フラグ (`run_grpo_qwen3_4b.reference.sh`, アドホックフラグ 0) を暫定 image (TE 無し) で B300 実行し、どの L3 patch が本当に必要かを切り分ける。

対象 image: 暫定 `slime:v0.2.4-sgl0.5.13-b300` (SGLang nightly, **TE 無し**)。

| 観測 | 結果 | 解釈 |
|---|---|---|
| TE 検出 | `Transformer Engine and Apex are not installed` | **L1-2 確定**。L3 patch の根本原因 |
| `apply_rope_fusion` | 素フラグでは `True` のまま | TE 無し + True なので train step で落ちるはずの構成 |
| SGLang rollout | 16 engine warmup 完了、rollout phase 到達 | **L2 (MemPool patch) があれば素フラグでも rollout は動く** |
| train step 到達 | 未到達のまま手動停止 | train step での TE/packed-seq エラーは未観測 (NGC 正攻法に切替えたため検証不要に) |

**結論**: 暫定 image (TE 無し) が L3 patch 地獄の根本原因と確定。SGLang nightly に上げたことで NGC base の TE/flash-attn ABI が壊れた。
→ **L1 を正す (リファレンス Dockerfile を B300 でビルド) のが正攻法**。検証は新 image `slime:v0.2.4-ngc-b300` で実施。

### NGC リファレンス image ビルド (L1 正攻法)
- リファレンス `slime.Dockerfile` (NGC pytorch:26.02 + TE + SGLang 0.5.12.post1) を**無改変**で B300 ビルド。
- 全 stage ビルド成功 = **NGC 26.02 + SGLang 0.5.12 が B300 (sm_103) で成立**。
- [トラブル] ECR push 403 = docker secret のトークンが 12h で失効 (2日前作成)。→ secret 再発行で解決。
- [改善] BuildKit の layer cache が pod ローカルで Job 再作成時に消える。次回は `--export-cache type=registry,ref=<ecr>:buildcache` を使うべき。
- [確認] image 内に `transformer_engine 2.12.0+5671fd36` 同梱を `import` で確認。Ray は 16 GPU (2 node x 8) を認識。

### NGC image での素フラグ実行 (L1 正攻法の検証 / 2026-06-20)

対象 image: `slime:v0.2.4-ngc-b300` (NGC base, **TE 2.12 同梱**)。recipe は
`run_grpo_qwen3_4b.reference.sh` (アドホックフラグ 0、リファレンスとの差分は MODEL_ARGS
の literal 展開 1 点のみ)。env_vars は `env_vars.akazawt` (FSx パスのみ調整)。

| 観測 | 結果 | 解釈 |
|---|---|---|
| `hf_validate_args` | **通過** | MODEL_ARGS が train.py に正しく到達 (literal 展開修正が効いた) |
| TE 依存フラグ (`--no-rope-fusion` 等) | **不要** | 素フラグで model build に到達。L3-1 が**消えた**ことを実証 |
| `--use-dynamic-batch-size` (packed thd) | **素のまま起動** | L3-2 (qkv-format bshd 回避) も**不要** |
| SGLang 16 engine | 全 engine 起動・モデルロード完了 (shards 3/3) | rollout 側 OK |
| Blackwell 認識 | `CUTLASS disabled on B200 ... Using auto backend` | SGLang が sm_10x を自動判別し安定 backend を選択 |
| **CUDA graph capture/compile** | `Capturing batches` → `Capturing/Compiling num tokens` に到達、`sglang::scheduler` 8 プロセスが R state で CPU 82% (compile 実行中) | **L2 MemPool patch 無しで capture/compile 区間に突入** |
| `captures_underway` / MemPool abort | **0 件** (grep で確認) | 前回 nightly で必須だった L2 が NGC SGLang 0.5.12 では**不要の可能性が濃厚** (compile 完走の最終確認待ち) |

**中間結論 (重要)**:
- **L3-1 / L3-2 は消えた** — TE 同梱の NGC image なら `--no-rope-fusion` 系・`--qkv-format bshd` は不要。
  recipe はリファレンスとほぼ同一 (literal 展開の 1 点のみ) で素フラグ起動できた。
  → ユーザー指示「リファレンスの方が優れているならそちらに合わせる」「美しい設計」を満たす形に到達。
- **L2 (MemPool) も不要の可能性** — nightly では graph capture 直前で abort したが、NGC SGLang
  0.5.12 では patch 無しで capture/compile に突入し abort 0 件。PyTorch 2.11 の MemPool バグは
  SGLang のバージョン/graph backend 実装に依存していた疑い。最終確認は compile 完走後に行う。
- 残る B300 固有差分の候補は **L3-3 (no-offload-rollout/train)** のみ。これは torch_memory_saver の
  KV cache unmap 問題への設計判断で、素フラグ (offload 有効) で colocated が成立するかは
  この実行の train step 到達時に判明する。

---

## SGLang HTTP server が立たない問題の真因 (確定 / 2026-06-20)

素フラグで model build を通過した後、**SGLang rollout engine の HTTP server (uvicorn,
port 15000) が listen せず `_wait_server_healthy` が無限待ち**になり RolloutManager が
PENDING_CREATION で固着する問題に長時間ブロックされた。複数の仮説を実測で潰した結果、
**真因は uvicorn の log_level 不正値**と確定した。

### 切り分けの全履歴 (どれも症状で、真因は最後の1つ)

| # | 疑った原因 | 検証結果 | 判定 |
|---|---|---|---|
| 1 | capture が遅い | scheduler は `on_idle`/`recv_requests` で ready (py-spy) | 症状であり主因でない |
| 2 | L2 MemPool abort | NGC SGLang 0.5.12 では abort 0 件 | **無関係 (L2 不要確定)** |
| 3 | 16-engine の CPU 競合 | `--sglang-cuda-graph-max-bs 8` で capture 高速化 (52→4 batch) も HTTP server 立たず | 寄与するが主因でない |
| 4 | triton backend が必要 | triton は B300 で CPU tensor エラー誘発、逆効果 | **誤り (使わない)** |
| 5 | TP=8 の NCCL/EFA hang | py-spy で `broadcast_pyobj` は **gloo CPU group**。`GLOO_SOCKET_IFNAME=eth0` で capture 74/74 完走 | gloo の NIC 誤選択 (別の真の残差) |
| 6 | **uvicorn log_level 不正値** | **`--sglang-log-level WARN` を info に変えたら HTTP server が両 engine で起動 (fired up: 2)** | **★真因確定** |

### 真因の機序 (#6)

- リファレンス awsome-distributed-ai の run_grpo は `--sglang-log-level WARN` (大文字) を渡す。
- SGLang は `http_server.py:2230` で `log_level=server_args.log_level_http or server_args.log_level`
  を **uvicorn にそのまま転送**する。
- uvicorn の有効 log_level は **小文字のみ** `{critical,error,warning,info,debug,trace}`。
  `'WARN'` (および `'warn'`) は `KeyError` を投げ、**uvicorn が起動前に die** する。
- 結果: HTTP server プロセスが `_exit_function` (終了処理) に入り port 15000 を listen しない。
  scheduler(EngineCore) は ready (batch ループ) なのに HTTP server だけ不在 → `_wait_server_healthy`
  が `/health_generate` を永久に取れず hang → RolloutManager が固着。
- **単一 engine 検証が動いたのは `--log-level info` (小文字・有効値) を使ったため**。SLIME 経由は
  リファレンスの `WARN` を引き継いでいた。

### これはリファレンス awsome-distributed-ai 自体のバグ

`recipe/run_grpo_qwen3_4b.sh` の `--sglang-log-level WARN` は uvicorn では無効値。H100/p5 でも
同値のはずで、リファレンスが完全な smoke を通せていれば気付くはず。**2 つのリファレンス
(awsome-distributed-ai / mlkeita-pavel-blog) どちらにもこの問題への言及・回避策は無い**
(後者は vLLM 系で無関係、前者の Troubleshooting は CUDA OOM のみ)。我々が最初に踏んだ。

### 第2の壁: train actor の libcudart.so.12 (rollout 突破後に判明)

log_level 修正で rollout が ALIVE 起動した後、**MegatronTrainRayActor の Ray worker 起動が
`ActorUnschedulableError: Failed to startup worker after retrying 5 times` で失敗**。raylet ログに
`bash: error while loading shared libraries: libcudart.so.12: cannot open shared object file`。

- 真因 (コードで確定): `actor_group.py:62-72` で **`offload_train` 有効時に SLIME が
  `torch_memory_saver_hook_mode_preload.abi3.so` を train actor に `LD_PRELOAD`** する。
  この無印 .so は **cu12 リンク** (`ldd` で `libcudart.so.12 => not found`)。NGC image は
  CUDA 13 なので LD_PRELOAD した worker の bash が起動時に即死。
- image には **cu13 版 `..._preload_cu13.abi3.so` が存在し `libcudart.so.13` に正しくリンク**して
  いるが、SLIME は無印 (cu12) を決め打ちしている。
- 対処: **`--no-offload-train --no-offload-rollout`** で offload_train を切る → LD_PRELOAD 分岐
  自体がスキップされる。B300 192GB なら offload 不要なので設計判断としても妥当 (旧 L3-3 と一致)。

### 確定した修正 (env_vars.akazawt に隔離、recipe はリファレンス形を保持)

4 層すべてを env に隔離し、recipe 本体はリファレンス形 (フック `${SGLANG_EXTRA_ARGS}` /
`${TRAIN_EXTRA_ARGS}` / `${SGLANG_LOG_LEVEL}` のみ追加) を保つ:

```sh
export SGLANG_LOG_LEVEL="info"                            # ★真因: uvicorn 有効値 (WARN→info)
export SGLANG_EXTRA_ARGS="--sglang-cuda-graph-max-bs 8"   # B300 大 HBM の capture 範囲抑制
export TRAIN_EXTRA_ARGS="--no-offload-train --no-offload-rollout"  # libcudart.so.12 回避 (LD_PRELOAD cu12)
# raycluster env: GLOO_SOCKET_IFNAME=eth0                 # TP>1 の gloo broadcast NIC 明示
```

検証結果: 4 層適用後、`fired up: 2` (HTTP server) + `libcudart.so.12: 0件` +
`MegatronTrainRayActor ALIVE` (train actor 起動) を確認。これまで到達できなかった
Megatron init フェーズに突入。

---

## あるべき最終形

1. **L1 を正す**: NGC base + sm_103 + TE 同梱の正規 image を1つ作る。
2. これにより **L3-1, L3-2 が消える** → run_grpo はリファレンスとほぼ同一 (`--colocate --use-dynamic-batch-size` のみ) に戻せる。
3. **L2 (MemPool) と L3-3 (no-offload) だけが B300 固有の残差** として、明確な理由付きで残る。
4. patch は「リファレンス Dockerfile への diff」+「run_grpo への最小 diff」の2ファイルに集約し、各行に上記の L 番号と撤去条件をコメントする。
