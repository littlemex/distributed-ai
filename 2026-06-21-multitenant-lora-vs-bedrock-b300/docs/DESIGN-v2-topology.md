以上の調査データを確認しました。これをもとに設計書を出力します。

---

# Gemma 4 31B fp8 自ホスト vs Bedrock 公平比較 実験設計書

**作成日**: 2026-06-21  
**実行 deadline**: GPU (p6-b300.48xlarge, 8x B300) 解放前  
**根拠出所**: smoke pod 実測ログ (RUNLOG.md §6) / vLLM 0.21 ソースコード直読 / llm-d-disagg-b300 WORKLOG.md / Bedrock 実測 (RUNLOG.md §4c) / concurrency_sweep.py 既実装  
**低信頼は [LOW-CONF] で明示**

---

## 1. 結論: 推奨トポロジと理由

### 決定: 8x TP=1 独立レプリカ (data-parallel via 独立プロセス)

これは議論の余地がない。以下に根拠を示す。

**decode スループット ranking (B300 8枚、Gemma 4 31B fp8):**

| トポロジ | 構成 | step time | aggregate tok/s | 比 |
|---|---|---|---|---|
| **8x TP=1** | 8 独立プロセス | 4.08 ms (allreduce ゼロ) | ~1,962 | 100% (基準) |
| 4x TP=2 | 4 プロセス | 2.18 ms (+0.14 ms allreduce) | ~1,836 | -6% |
| 2x TP=4 | 2 プロセス | 1.44 ms | ~1,390 | -29% |
| 1x TP=8 | 1 プロセス | 60 layers x 2 allreduce x ~8us = 0.98 ms overhead | ~672 | -66% |

出所: B300 HBM3e ~8 TB/s (実測 GPU 275040 MiB)、fp8 model 32.62 GiB (RUNLOG.md §6 R10)、NVLink B300 intra-node ~1.8 TB/s から計算。

**なぜ TP=1 が圧倒するか**: Gemma 4 31B fp8 = 32.62 GiB。decode は memory-bandwidth-bound。TP=1 は allreduce コストゼロ。TP=8 は 60 layers x 2 allreduce で ~0.98 ms/step のオーバーヘッドがかかり、decode step 本体 (~0.51 ms) を上回る。TP を増やすほど aggregate throughput は単調に下がる。

**`--data-parallel-size 8` は使用不可**: vLLM 0.21 の `config/parallel.py` line 819-824 に明示的な `ValueError` がある:

```
if self.data_parallel_size > 1 and self.is_moe_model is False:
    raise ValueError("Offline data parallel mode is not supported/useful for dense models.")
```

Gemma 4 は dense (Gemma4ForConditionalGeneration)。起動時に例外が出る。

**TP=2 を選ぶ唯一の条件**: TTFT SLO が ~150 ms 以下の超厳格要件かつ prefill ボトルネックの場合のみ。本実験の user prompt は ~10 tokens (LoRA arm) であり、prefill は全く問題にならない。TP=1 が唯一の正解。

---

## 2. PD-disaggregation を使うか

### 決定: Arm B (multi-LoRA) には使わない。B0 (long sys-prompt) にのみ条件付き使用可能。

**Arm B に PD を使わない根拠** (高確信):

llm-d-disagg-b300/docs/WORKLOG.md の同一クラスタ・同一 image 実測:
- chat workload (1024/256, decode-heavy): native = llm-d = 32 req/s (unsaturated at 128 req/s rate)
- longctx workload (8192/256, prefill-heavy): llm-d = native の 4x

本実験の Arm B (user prompt ~10 tok, LoRA) は chat より更に短い。PD が利益をもたらす条件が完全に不在。

PD を入れた場合のコスト:
- 8 GPU を P+D に分割 → decode capacity が 50% 以下に
- NIXL KV transfer latency (~16 MB per batch、EFA counter 実測)
- NixlConnector + sidecar の運用複雑度

技術的互換性は確認済み: NIXL connector は LoRA 非認識 (`kv_transfer/` 以下に lora の grep ヒットゼロ)。P と D 両方に同じ adapter をロードすれば動く。ただし動いても goodput が下がる。

**B0 への PD 適用判断 (オプション)**:

B0 = 自ホスト + long system prompt (512 tok) + APC。Bedrock の Arm A と同一アクセスパターンで self-host の比較基準になる。この arm が prefill-heavy になる場合のみ、P:D = 1:1 の 2 レプリカ (16 GPU が必要) 構成で PD の利益が出る可能性がある。しかし **本実験は 8 GPU シングルノード**。B0 を PD で走らせるには 2 ノードが必要で、現在の予算外。

**結論**: B0 は PD なし。自ホスト 8x TP=1 に APC を有効にした形で Arm A と同一 input length の比較に使う。これだけで「hardware exclusivity が効いているか」の isolation が取れる。

---

## 3. 実験アーム設計

### アーム定義

| アーム | 名称 | モデル | config 配布方法 | input tokens | output tokens | 目的 |
|---|---|---|---|---|---|---|
| A | Bedrock system prompt | google.gemma-4-31b (bedrock-mantle) | per-request system prompt | 512 (sys) + ~10 (user) = ~522 | 64 | ベースライン / コスト比較対象 |
| B | self-host LoRA | gemma-4-31B-it fp8, 8x TP=1 | rank-16 adapter swap | ~10 (user のみ) | 64 | 主実験アーム |
| B0 | self-host sys-prompt | gemma-4-31B-it fp8, 8x TP=1 | per-request system prompt + APC | 512 (sys) + ~10 (user) = ~522 | 64 | 交絡分離用 isolation arm |

### 何を固定するか / 何を振るか

**固定 (全アームで厳密に統一):**
- user query テキスト: `"Summarize your configuration in one sentence."` (~10 tok, concurrency_sweep.py line 174 で hardcode 済み)
- max_tokens = 64 (output 固定)
- SLO: TTFT <= 2000 ms, TPOT <= 80 ms
- 計測ツール: `scripts/concurrency_sweep.py` の同一コードパス (SigV4/none の auth 差分のみ)
- tenant 数: 1000
- Zipf seed: 0
- requests per stage: 400

**振る (architectural variable として明示):**
- Arm A: input = sys_prompt(512) + user(~10) = ~522 tok (per-request token コスト発生)
- Arm B: input = user(~10) tok のみ (adapter swap コストは token 計上なし)
- Arm B0: input = sys_prompt(512) + user(~10) = ~522 tok (A と同 input length だが dedicated HW)

**公平比較の明示声明 (スライド用):**

> 本比較は同一ワークロードの比較ではない。論理タスク (同一 user query、同一 output length) は一致させ、「テナント設定の注入方式」という architectural な差異を計測する。input token 数が異なること自体が計測対象の変数である。

### B0 が必要な理由

B0 なしだと A vs B の差が「Bedrock managed vs 専有 HW」と「sys-prompt vs LoRA」の 2 変数が混在する。B0 は input length を A と揃えることで「HW 専有の効果だけ」を分離できる。1 回の concurrency sweep (~60 分) でこの isolation が得られる。

---

## 4. 公平比較プロトコル

### Workload 固定定義

```
user_query = "Summarize your configuration in one sentence."
max_tokens = 64
ignore_eos = True (自ホストのみ: ダミー adapter の出力品質非依存)
streaming = True (TTFT を first non-empty chunk として計測)
tenant_count = 1000
zipf_s = 1.1, seed = 0
requests_per_stage = 400 (p99 誤差 ±7% @ 95% CI)
```

### Token 会計 (アーム別)

```
Arm A (Bedrock):
  prompt_tokens = sys_prompt_tokens + user_tokens   ← usage.prompt_tokens で実測
  output_tokens = usage.completion_tokens           ← 実測
  cost_per_req ($) = (prompt_tok * 0.14 + output_tok * 0.40) / 1e6
  ※ cached_tokens = 0 全条件で確認済み (RUNLOG.md §4 R3): フル input 課金

Arm B / B0 (self-host):
  token に依らない時間固定費
  cost_per_req ($) = C_CB / (req_s * 3600)   [C_CB = $93.60/hr]
  cost_per_1M_out ($) = C_CB / (out_tok_s * 3.6e-3)
```

### SLO 定義

| SLO | 値 | 根拠 |
|---|---|---|
| TTFT_SLO | 2000 ms | Bedrock 単発 TTFT p50 = ~350 ms の 5.7 倍。Bedrock 有利に見えないよう緩め設定 |
| TPOT_SLO | 80 ms/tok | Bedrock 実測 TPOT = 5.6-9.4 ms の 8-14 倍。SLO が Bedrock hostile にならないよう設定 |

**goodput 定義 (2 種類を必ず報告):**

```python
# good_request: TTFT <= 2000ms AND TPOT <= 80ms AND error なし
goodput_req_s = count(good) / wall_clock_s          # 通常指標
achievable_goodput_pct = count(good) / total_attempted * 100  # Bedrock queuing を捕捉
```

Bedrock は 503 を返さずキューで TTFT を伸ばす (R9 で確認: n_503=0 全条件)。`achievable_goodput_pct` が Bedrock の実質キャパシティ上限を示す唯一の指標。

### Concurrency Sweep 水準

```
concurrency levels = [1, 5, 10, 20, 40, 100, 200, 400, 800]
```

設計根拠:
- Bedrock 崩壊点: concurrency 10 → 20 で TTFT p50 が 360 ms → 37,436 ms (R9)。1/5/10/20/40 で崩壊クリフを 5 点捕捉
- self-host 飽和点: 未計測 [LOW-CONF]。fp8 KV プールで ~1000 concurrent seqs at avg 500 tok。100/200/400/800 で飽和カーブを捕捉
- Bedrock conc 100 で goodput=100% (sweep データ: TTFT p50=743ms) という非単調挙動あり → 100 以上も必須

### 交絡の扱い

| 交絡 | 対策 |
|---|---|
| JIT warmup (B/B0 のみ) | 計測前に concurrency=10 x 100 requests を warm-up ステージとして実行 (結果に含めない)。TRITON_CACHE_DIR/FLASHINFER_CACHE_DIR をノード NVMe に永続化 |
| Bedrock 時刻依存 | Bedrock の全 concurrency level を 1 セッションで連続実行。開始時刻を results JSON に記録 |
| LoRA cold swap | 事前に `bench_lora_swap_cost.py` でマイクロベンチ (hot-hit / CPU->GPU / disk->GPU の TTFT 絶対値を計測)。この値を TTFT 差分の mechanistic 説明に使う |
| adapter 配布の対称性 | 8 replicas 全てに同じ 1000 adapter を POST 登録してから sweep 開始 |
| B routing サブ実験 | round-robin (K8s Service default) と affinity (tenant_affinity_proxy.py consistent-hash) の 2 sub-run。差が swap_cost 以内なら「round-robin 十分」を結論とする |

---

## 5. Throughput 最大化 vLLM 起動設定

### 基準値 (smoke pod 実測、RUNLOG.md §6 R10/R14)

- GPU: 275040 MiB = 268 GiB HBM3e
- Model (fp8): 32.62 GiB (online quantize、checkpoint に quantization_config なし = Fp8OnlineLinearMethod)
- KV @ 0.90 util, max_loras=4: 202.6 GiB / 240,559 tokens (bf16 KV)
- CUDA graph: 1.53 GiB
- adapter サイズ (rank-16, bf16): 247.2 MB (123.6M params, synth_dummy_lora.py 実測)
- Attention backend: TRITON_ATTN (自動強制。head_dim=256 vs global_head_dim=512 の heterogeneous で vLLM が自動選択、config.py line 58-110)

### KV budget 計算 (最適化設定)

```
GPU total: 268 GiB
non-KV overhead:
  model (fp8): 32.62 GiB
  CUDA graph:  1.53 GiB
  LoRA buf @ max_loras=32: 32 * 247.2 MB = 7.72 GiB
  CUDA runtime/fragmentation: ~3.5 GiB
  subtotal: ~45.4 GiB

KV available @ gpu_util=0.95:
  268 * 0.95 - 45.4 = 209.2 GiB

KV tokens (bf16, measured ratio 202.6/240559 = 884 KB/tok):
  209.2 GiB / 884 KB = ~248K tokens

KV tokens (fp8_e4m3, 1 byte/element = 1/2 of bf16):
  ~496K tokens  ← 2x

max concurrent seqs @ max_model_len=4096:
  bf16: ~61 seqs
  fp8 KV: ~121 seqs
  at avg_total=400 tok: fp8 KV = ~1242 seqs
  max_num_seqs=1024 が effective cap (avg > ~490 tok のとき)
```

注: startup log の `--gpu-memory-utilization=0.90 is equivalent to 0.8943 without CUDA graph memory profiling` メッセージが示す通り、実効値はわずかに低いが計算の誤差範囲内。

### 決定フラグ一覧 (per replica)

| フラグ | 値 | 根拠と出所 |
|---|---|---|
| `--tensor-parallel-size` | 1 | §1 参照。allreduce ゼロが最大 aggregate throughput |
| `--quantization` | fp8 | online quant。model 32.62 GiB (RUNLOG R10) |
| `--kv-cache-dtype` | fp8_e4m3 | KV token pool を bf16 の 2x (248K -> 496K) に。最大の単一スループットレバー。精度劣化はこの実験では許容 |
| `--enable-lora` | (flag) | |
| `--max-loras` | 32 | GPU hot-set。32 * 247.2 MB = 7.72 GiB。Zipf(s=1.1) top-32 = traffic の ~40% をカバー。v1 scheduler は超過時 defer (RuntimeError でクラッシュせず — R13 で確認) |
| `--max-lora-rank` | 16 | adapters の rank に合わせる (RUNLOG R14) |
| `--lora-dtype` | bfloat16 | Triton punica kernel は fp16/bf16 のみ対応。fp8 LoRA は未サポート (DESIGN.md §5) |
| `--max-cpu-loras` | 1000 | 全 adapter を CPU RAM 常駐。1000 * 247.2 MB = 241 GiB / 4096 GiB RAM (5.9%)。cold miss が disk I/O でなく H2D copy (~7 ms) になる |
| `--gpu-memory-utilization` | 0.95 | smoke の 0.90 から +6.6 GiB KV (3.3% 増)。268 GiB GPU での非 KV オーバーヘッド ~45.4 GiB が確認済みのため余裕 |
| `--max-model-len` | 4096 | A/B/B0 全アームで最大 input ~522 tok + output 64 tok = ~586 tok。4096 は十分。KV pool を最大化 |
| `--max-num-seqs` | 1024 | B300 の vLLM default (arg_utils.py line 2248-2265: >70 GiB GPU で 1024)。fp8 KV で ~1242 concurrent seqs (avg 400 tok) を収容可能なので 1024 は KV OOM しない |
| `--max-num-batched-tokens` | 16384 | default 8192 から 2x。1024 decode + 15360 prefill slots を確保。TTFT 改善に寄与。初回 JIT compile あり (TRITON_CACHE_DIR で永続化すれば 2 回目以降不要) |

### 起動コマンド (per replica)

```bash
export VLLM_ALLOW_RUNTIME_LORA_UPDATING=true
export VLLM_LORA_ENABLE_DUAL_STREAM=1          # sm_103 対応確認済み (envs.py:1788, base_linear.py:30)
export TRITON_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/triton
export FLASHINFER_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/flashinfer
export VLLM_CACHE_ROOT=/mnt/k8s-disks/0/jit_cache/vllm
export GLOO_SOCKET_IFNAME=eth0                 # MEMORY.md slime-b300-smoke-true-rootcauses 確認済み
export HF_HOME=/mnt/k8s-disks/0/local_scratch/hf_cache

CUDA_VISIBLE_DEVICES=${GPU_IDX} vllm serve google/gemma-4-31B-it \
  --tensor-parallel-size 1 \
  --quantization fp8 \
  --kv-cache-dtype fp8_e4m3 \
  --enable-lora \
  --max-loras 32 \
  --max-lora-rank 16 \
  --lora-dtype bfloat16 \
  --max-cpu-loras 1000 \
  --gpu-memory-utilization 0.95 \
  --max-model-len 4096 \
  --max-num-seqs 1024 \
  --max-num-batched-tokens 16384 \
  --port $((8000 + GPU_IDX))
```

`VLLM_LORA_ENABLE_DUAL_STREAM=1` は base linear forward (default stream) と LoRA SGMV 計算 (aux stream) をオーバーラップさせる。sm_version gate なし (base_linear.py:30 確認)。rank=16 の小さい SGMV kernel が大きい base GEMM と並走し TTFT を削減。

---

## 6. 8 GPU 割り当て図

### 構成: 8x TP=1 独立レプリカ

```
p6-b300.48xlarge (8x B300 SXM6-AC)
┌───────────────────────────────────────────────────────────────┐
│  B300-0          B300-1          B300-2          B300-3        │
│  vllm:8000       vllm:8001       vllm:8002       vllm:8003    │
│  268 GiB HBM     268 GiB HBM     268 GiB HBM     268 GiB HBM  │
│  model: 32.6G    model: 32.6G    model: 32.6G    model: 32.6G  │
│  KV: ~209G fp8   KV: ~209G fp8   KV: ~209G fp8   KV: ~209G fp8 │
│  LoRA buf: 7.7G  LoRA buf: 7.7G  LoRA buf: 7.7G  LoRA buf: 7.7G│
│  max_loras=32    max_loras=32    max_loras=32    max_loras=32  │
│                                                                 │
│  B300-4          B300-5          B300-6          B300-7        │
│  vllm:8004       vllm:8005       vllm:8006       vllm:8007    │
│  (same as above)                                               │
└───────────────────────────────────────────────────────────────┘
         ↑
  [tenant_affinity_proxy.py :9000]
  consistent-hash on model= field (= adapter-{i} = tenant id)
  round-robin sub-run も実施 (差分計測)
         ↑
  [concurrency_sweep.py]  --base-url http://proxy:9000/v1
```

**CPU RAM 割り当て:**

```
OS / system: ~100 GiB (余裕)
vLLM x8 プロセス:
  各プロセスの max_cpu_loras=1000: 241 GiB
  8 プロセス合計: 1,928 GiB  (4096 GiB の 47%)
  → 全プロセスが adapter 全量を CPU に保持可能
```

注: 各プロセスは独立して 1000 adapter を CPU ロードする。デデュープなし (vLLM は lora_int_id で管理、lora_path ではない)。1 ノード合計 ~1.9 TB の CPU RAM 消費。4096 GiB の範囲内。

**PD は使用しない** (§2 で確定)。8 GPU 全量が decode に使われる。

---

## 7. コストモデル

### 確定定数

```
C_CB = $93.60/hr  (CB, p6-b300.48xlarge, us-west-2, Linux)
C_OD = $142.416/hr (OD, 同上)

Bedrock Gemma 4 31B: P_in=$0.14/1M tok, P_out=$0.40/1M tok
Bedrock に prompt caching なし (RUNLOG R3: cached_tokens=0 全条件で実測確認)
```

### コスト式

**Arm A (Bedrock) - 1 logical request あたり:**

```
cost_A($) = (S + U) * 0.14/1e6 + O * 0.40/1e6

S = system_prompt_tokens (experiment: 512)
U = user_tokens (~10)
O = output_tokens (experiment: 64)

Example (S=512, U=10, O=64):
  cost_A = (522 * 0.14 + 64 * 0.40) / 1e6 = $0.0000987/req = $98.7/1M req

Bedrock cost は S に線形増加。S が 2x になれば cost もほぼ 2x。
```

**Arm B / B0 (self-host) - S 非依存:**

```
cost_B_per_req($) = C_CB / (achieved_req_s * 3600)
cost_B_per_1M_out($) = C_CB / (out_tok_s * 3.6e-3)

achieved_req_s は concurrency sweep で計測。
```

### system prompt サイズ S の関数での break-even (CB pricing)

| S (sys_prompt_tokens) | Bedrock $/1M req | BE_req_s (CB) | BE_out_tok_s (O=64) |
|---|---|---|---|
| 128 | $87/1M | 299 req/s | 19,130 tok/s |
| 512 | $99/1M (実験値) | 263 req/s | 16,830 tok/s |
| 2048 | $314/1M | 83 req/s | 5,310 tok/s |
| 8192 | $1,163/1M | 22 req/s | 1,440 tok/s |

```
BE_req_s(S) = C_CB * 1e6 / (3600 * ((S + U) * 0.14 + O * 0.40))
BE_out_tok_s = BE_req_s * O
```

### achieved_req_s の関数での自ホストコスト

| achieved_req_s (node aggregate) | self_cost $/1M req | Bedrock A (S=512) $99/1M との比 |
|---|---|---|
| 50 req/s | $520/1M | 5.3x 高い (Bedrock 優位) |
| 100 req/s | $260/1M | 2.6x 高い |
| 263 req/s | $99/1M | 損益分岐 (S=512) |
| 500 req/s | $52/1M | 1.9x 安い |
| 1000 req/s | $26/1M | 3.8x 安い |

[LOW-CONF] 8x TP=1 Gemma 4 31B fp8 on B300 の実 achieved_req_s は未計測。これが唯一の決定値。

### 測るべき唯一の決定値

**r_sat: SLO 達成下での aggregate req/s (8 replica 合計)**

これが決まると:
- r_sat > 263 req/s → S=512 で自ホストが Bedrock 31B より安い (CB 条件)
- r_sat > 86 req/s → S=2048 で自ホストが安い
- r_sat > 22 req/s → S=8192 で自ホストが安い

スループット優位は条件なし確定 (Bedrock の SLO 達成上限 = 0.41 req/s、RUNLOG R9 実測)。

1000 テナントが 1 req/10 min = 1.67 req/s の aggregate 需要でも、Bedrock の SLO cap 0.41 req/s を 4x 超える。実際の多テナント workload では Bedrock は実質使えない。

---

## 8. 実行手順

### GPU 解放前の最終チェックリスト

```bash
# 1. EKS cluster 接続確認
kubectl get nodes -l nvidia.com/gpu.product=NVIDIA-B300-SXM6-AC

# 2. namespace 確認
kubectl get namespace mt-serving

# 3. Bedrock 計測ツール動作確認 (GPU 不要)
cd <repo>
python scripts/concurrency_sweep.py \
  --base-url https://bedrock-mantle.us-west-2.api.aws/openai/v1 \
  --model google.gemma-4-31b --auth sigv4 \
  --dataset data/bedrock_dataset_medium_1000tenants.jsonl \
  --concurrency 1 --requests-per-stage 5 --max-tokens 64 \
  --slo-ttft-ms 2000 --slo-tpot-ms 80 \
  --out results/preflight-check.json

# 4. JIT cache ディレクトリ存在確認 (Pod内)
# kubectl exec smoke-vllm-lora -- ls /mnt/k8s-disks/0/jit_cache/

# 5. HF cache に gemma-4-31B-it があるか確認
# kubectl exec smoke-vllm-lora -- ls /mnt/k8s-disks/0/local_scratch/hf_cache/hub/ | grep gemma-4-31

# 6. adapter 生成ツール確認 (synth_dummy_lora.py が動くか)
# kubectl exec smoke-vllm-lora -- python scripts/synth_dummy_lora.py --help
```

### Step 1: adapter 1000 枚生成

```bash
# pod 内で実行 (既存 smoke pod またはフレッシュな pod)
kubectl -n mt-serving exec -it smoke-vllm-lora -- bash -c "
python /workspace/scripts/synth_dummy_lora.py \
  --model google/gemma-4-31B-it \
  --n 1000 \
  --out-dir /mnt/k8s-disks/0/adapters/gemma4-31b \
  --rank 16
"
# 期待: 1000 adapter dirs, ディスク消費 ~247 MB (hardlink) + 1000 x config JSON
# 所要時間: ~5-10 分
```

### Step 2: 8 replica 起動 (DaemonSet or 8x Pod)

`manifests/10-vllm-8replica.yaml` を作成して apply:

```yaml
# manifest の骨格: 8 replicas を StatefulSet で GPU_IDX=0..7 に割り当て
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: vllm-gemma4-31b
  namespace: mt-serving
spec:
  replicas: 8
  selector: {matchLabels: {app: vllm-mt}}
  template:
    metadata: {labels: {app: vllm-mt}}
    spec:
      nodeSelector: {nvidia.com/gpu.product: NVIDIA-B300-SXM6-AC}
      tolerations:
        - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}
        - {key: vpc.amazonaws.com/efa, operator: Exists, effect: NoSchedule}
        - {key: workload, operator: Equal, value: bench, effect: NoSchedule}
        - {key: capacity-reservation, operator: Exists, effect: NoSchedule}
      containers:
        - name: vllm
          image: <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/vllm-uccl-ep:vllm0.21.0-uccl-0dc87eb-cu13-b300-fix1
          env:
            - {name: VLLM_ALLOW_RUNTIME_LORA_UPDATING, value: "true"}
            - {name: VLLM_LORA_ENABLE_DUAL_STREAM, value: "1"}
            - {name: TRITON_CACHE_DIR, value: /mnt/k8s-disks/0/jit_cache/triton}
            - {name: FLASHINFER_CACHE_DIR, value: /mnt/k8s-disks/0/jit_cache/flashinfer}
            - {name: VLLM_CACHE_ROOT, value: /mnt/k8s-disks/0/jit_cache/vllm}
            - {name: GLOO_SOCKET_IFNAME, value: eth0}
            - {name: HF_HOME, value: /mnt/k8s-disks/0/local_scratch/hf_cache}
          command: ["bash","-lc","
            GPU_IDX=$(hostname | awk -F- '{print $NF}') &&
            CUDA_VISIBLE_DEVICES=${GPU_IDX} vllm serve google/gemma-4-31B-it
              --tensor-parallel-size 1
              --quantization fp8
              --kv-cache-dtype fp8_e4m3
              --enable-lora --max-loras 32 --max-lora-rank 16
              --lora-dtype bfloat16 --max-cpu-loras 1000
              --gpu-memory-utilization 0.95
              --max-model-len 4096
              --max-num-seqs 1024
              --max-num-batched-tokens 16384
              --port 8000
          "]
          resources:
            requests: {cpu: "20", memory: "512Gi", nvidia.com/gpu: "1"}
            limits: {nvidia.com/gpu: "1"}
          volumeMounts:
            - {name: model-cache, mountPath: /mnt/k8s-disks/0}
            - {name: dshm, mountPath: /dev/shm}
      volumes:
        - {name: model-cache, hostPath: {path: /mnt/k8s-disks/0, type: DirectoryOrCreate}}
        - {name: dshm, emptyDir: {medium: Memory, sizeLimit: 64Gi}}
```

### Step 3: adapter 1000 枚を全 replica に POST 登録

```bash
# scripts/register_adapters.sh を全 8 replica に対して実行
for replica in 0 1 2 3 4 5 6 7; do
  PORT=$((8000 + replica))
  for i in $(seq 0 999); do
    curl -s -X POST "http://localhost:${PORT}/v1/load_lora_adapter" \
      -H 'Content-Type: application/json' \
      -d "{\"lora_name\":\"adapter-${i}\",\"lora_path\":\"/mnt/k8s-disks/0/adapters/gemma4-31b/adapter-${i}\"}" \
      > /dev/null &
    [ $((i % 50)) -eq 0 ] && wait
  done
  wait
  echo "[OK] replica ${replica} (port ${PORT}): 1000 adapters registered"
done
```

### Step 4: swap-in マイクロベンチ (計測前に実施)

```bash
python scripts/bench_lora_swap_cost.py --port 8000
# 出力: hot=XXms  cpu_swap=YYms  swap_cost~=ZZms
# ZZ が数 ms なら round-robin で十分 (登壇論点2の根拠)
```

### Step 5: JIT warmup

```bash
python scripts/concurrency_sweep.py \
  --base-url http://proxy:9000/v1 \
  --model google/gemma-4-31B-it \
  --auth none \
  --adapters 1000 --zipf 1.1 \
  --concurrency 10 --requests-per-stage 100 \
  --max-tokens 64 --slo-ttft-ms 2000 --slo-tpot-ms 80
# この結果は discardする (warmup のみ)
```

### Step 6: 本計測 concurrency sweep (全 3 アーム)

```bash
# Arm A: Bedrock (SigV4)
python scripts/concurrency_sweep.py \
  --base-url https://bedrock-mantle.us-west-2.api.aws/openai/v1 \
  --model google.gemma-4-31b --auth sigv4 \
  --dataset data/bedrock_dataset_medium_1000tenants.jsonl \
  --concurrency 1 5 10 20 40 100 200 400 800 \
  --requests-per-stage 400 --max-tokens 64 \
  --slo-ttft-ms 2000 --slo-tpot-ms 80 \
  --out results/bedrock-31b-medium-1000t-final.json

# Arm B (round-robin): 自ホスト LoRA, 先に round-robin を計測
python scripts/concurrency_sweep.py \
  --base-url http://vllm-rr-svc:9001/v1 \
  --model google/gemma-4-31B-it \
  --auth none --adapters 1000 --zipf 1.1 \
  --concurrency 1 5 10 20 40 100 200 400 800 \
  --requests-per-stage 400 --max-tokens 64 \
  --slo-ttft-ms 2000 --slo-tpot-ms 80 \
  --out results/vllm-31b-lora-1000t-rr.json

# Arm B (affinity): tenant_affinity_proxy.py を経由
python scripts/concurrency_sweep.py \
  --base-url http://vllm-affinity-proxy:9000/v1 \
  --model google/gemma-4-31B-it \
  --auth none --adapters 1000 --zipf 1.1 \
  --concurrency 1 5 10 20 40 100 200 400 800 \
  --requests-per-stage 400 --max-tokens 64 \
  --slo-ttft-ms 2000 --slo-tpot-ms 80 \
  --out results/vllm-31b-lora-1000t-affinity.json

# Arm B0: 自ホスト sys-prompt (isolation arm)
python scripts/concurrency_sweep.py \
  --base-url http://vllm-rr-svc:9001/v1 \
  --model google/gemma-4-31B-it \
  --auth none \
  --dataset data/bedrock_dataset_medium_1000tenants.jsonl \
  --concurrency 1 5 10 20 40 100 200 400 800 \
  --requests-per-stage 400 --max-tokens 64 \
  --slo-ttft-ms 2000 --slo-tpot-ms 80 \
  --out results/vllm-31b-sysprompt-1000t-b0.json
```

### Step 7: Prometheus メトリクス収集 (計測中 parallel)

```bash
# 計測中に monitor_lora_swap.py を並走
python scripts/monitor_lora_swap.py &
# -> swap-in event を 2s 間隔でログ、concurrency 別の swap rate を確認

# vLLM /metrics endpoint から kv_cache_usage_perc と lora_requests_info を scrape
for port in 8000 8001 8002 8003 8004 8005 8006 8007; do
  while true; do
    curl -s http://localhost:${port}/metrics | \
      grep -E 'kv_cache_usage|lora_requests_info|num_requests_running' >> \
      results/metrics_port${port}.txt
    sleep 5
  done &
done
```

---

## 9. リスクとオープンクエスチョン

### リスク (対処策あり)

**R1: fp8_e4m3 KV による出力品質劣化**  
KV fp8 は精度が落ちる。ダミー adapter 使用でそもそも出力品質を評価しないため、concurrency sweep (throughput 計測) では影響なし。ただし起動後に数件のリファレンスプロンプトで明らかな出力崩壊 (repetition, empty) が見えたら bf16 に戻す。

**R2: max_num_batched_tokens=16384 での TRITON_ATTN JIT compile spike**  
Triton は batch size ごとにカーネルをコンパile。16384 は smoke では試していない。初回ヒット時に数秒の spike が出る可能性。対策: warmup step (Step 5) で事前に compile させる + TRITON_CACHE_DIR で永続化。

**R3: Bedrock 時刻依存性**  
R9 で確認した Bedrock の崩壊挙動 (conc 20 で 37 s) は backend 負荷によって変動する可能性。対策: Arm A の全 concurrency を 1 セッションで連続計測し、timestamps を記録。

**R4: 1000 adapter POST 登録の時間**  
1000 adapter x 8 replicas で 8000 回の POST。50 並列で ~160 秒/replica。8 replica 直列なら ~22 分。事前に全 replicas が ready になっているかを確認してから登録を開始すること。

**R5: adapter shape mismatch**  
synth_dummy_lora.py が生成した adapter の shape が vLLM の期待する packed 形式と一致しない可能性 (RUNLOG R12: heterogeneous layers で Gemma3 用 adapter が mismatch した実例あり)。Gemma4 用 adapter は RUNLOG R14 で smoke 時に確認済みだが、1000 枚生成後に改めて数枚を POST して確認すること。

### オープンクエスチョン (計測前に答えが出ない)

**Q1 (最重要)**: r_sat - 8x TP=1 Gemma 4 31B fp8 の SLO 達成下での aggregate req/s。これが break-even 表の判断基準。263 req/s (S=512) を超えるかどうかが今回の GPU 実験の核心。[LOW-CONF: 達成可能範囲かどうか不明]

**Q2**: affinity vs round-robin の TTFT 差分の絶対値。swap-in マイクロベンチ (Step 4) で swap_cost の桁を把握してから本計測に臨むことで解釈が容易になる。差が < 10 ms なら「round-robin 十分」が結論。

**Q3**: Bedrock conc 100 での goodput 回復 (R9 + sweep データで conc 100 は goodput 100%) が今回の 9 point sweep でも再現するか。非単調挙動の原因は未解明 (内部 batch scheduling 推測) [LOW-CONF]。

**Q4**: CUDA graph memory estimate が max_loras=32 + VLLM_LORA_ENABLE_DUAL_STREAM=1 で smoke 時の 1.53 GiB から増加するか。起動ログの `Estimated CUDA graph memory` を確認し、想定外に大きければ gpu_memory_utilization を 0.93-0.94 に下げて再起動。

**Q5**: B0 arm での APC hit rate。vLLM の APC は replica をまたがないため、同一テナントが毎回同じ replica に来る (affinity proxy 使用) 場合のみ hit rate が高くなる。B0 を affinity routing で計測することで APC の効果を最大化できるが、そうすると B0 の優位が「APC の効果」なのか「HW 専有の効果」なのかが分離できなくなる。B0 は round-robin で計測して APC 効果を抑制し、純粋な HW 専有効果を測る方が isolation として正確。

---

## 関連ファイルへのパス

設計書:
- `<repo>/docs/DESIGN.md`
- `<repo>/docs/RUNLOG.md`

スクリプト:
- `<repo>/scripts/concurrency_sweep.py`
- `<repo>/scripts/bench_lora_swap_cost.py`
- `<repo>/scripts/tenant_affinity_proxy.py`
- `<repo>/scripts/monitor_lora_swap.py`
- `<repo>/scripts/synth_dummy_lora.py`

既存 manifest (smoke pod 参照):
- `<repo>/manifests/00-smoke-vllm-lora-4b.yaml`

既存測定結果:
- `<repo>/results/bedrock-31b-short-trueasync.json`
- `<repo>/results/bedrock-31b-short-sweep.json`