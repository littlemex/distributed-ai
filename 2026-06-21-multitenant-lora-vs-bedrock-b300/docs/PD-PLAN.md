以下は Gemma 4 31B fp8 PD disaggregation の具体的・実行可能なプランである。

---

## 1. 結論: PD は Gemma 4 で動くか

**見立て: 条件付き YES、だが smoke test が必須の Gate になる。**

Gemma 4 の heterogeneous attention (50 sliding-window layers: kv_heads=16/head_dim=256、10 global layers: kv_heads=4/head_dim=512) は vLLM 0.21 で `unify_kv_cache_spec_page_size()` により page_size_bytes=131072 に統一される。`NixlConnector` の assertion ("All remote layers must have the same block size") は通過する見込みが高い。TRITON_ATTN バックエンドは `NixlConnector.prefer_cross_layer_blocks` リストに含まれる。fp8_e4m3 static quantization は compatibility hash に組み込まれており、P/D 両方で同一フラグを使えば問題ない。

[出所: `/usr/local/lib/python3.12/dist-packages/vllm/v1/core/kv_cache_utils.py:1007`, `nixl/connector.py:68-72`, `nixl/worker.py:1487-1492`]

**残存リスク (MEDIUM)**: TP=8 で全 attention layers を head-split すると、full_attention の 4 heads を 8 ranks に割ると 0.5 heads/rank になりアサーションが飛ぶ可能性がある。このため TP=1 を採用する。

**推奨 GPU 割当: 4P + 4D、TP=1 each (intra-node)**

- 4 GPU で prefill 専用、4 GPU で decode 専用
- CUDA_VISIBLE_DEVICES による分離。同一 pod 内で 2 プロセスを並走させる
- TP=1 なら full_attention/sliding head-count の不均一は TransferTopology に影響しない
- NVLink B300 全対全 NV18 なので intra-node KV 転送コスト ~7 ms / 30K-token request (推算値、12.6 GB at ~1.8 TB/s)

[出所: `investigations/llm-d-disagg-b300/docs/RESEARCH.md §4`, `WORKLOG.md Phase 2 topology notes`]

---

## 2. 正確な起動手順

### 共通事前設定

```bash
# pod に入る
kubectl -n mt-serving exec -it vllm-8replica -- bash

# 以下を pod 内で実行
NODE_IP=$(hostname -I | awk '{print $1}')
IFACE=$(ip -o -4 addr show | grep "$NODE_IP" | awk '{print $2}' | head -1)
MODEL=google/gemma-4-31b-it   # fp8 variant の実際のパスに要確認
KV_CFG='{"kv_connector":"NixlConnector","kv_role":"kv_both","kv_load_failure_policy":"fail","kv_connector_extra_config":{"backends":["LIBFABRIC"]}}'

# JIT キャッシュディレクトリ確認 (既存から引き継ぐ)
mkdir -p /mnt/k8s-disks/0/jit_cache/{triton,flashinfer,vllm,cute}
```

### kv-transfer-config JSON (確定)

```json
{
  "kv_connector": "NixlConnector",
  "kv_role": "kv_both",
  "kv_load_failure_policy": "fail",
  "kv_connector_extra_config": {
    "backends": ["LIBFABRIC"]
  }
}
```

[出所: `manifests/20-prefill-qwen3.yaml line 125`, `manifests/40-dsv3-prefill.yaml line 226`]

### Prefill 起動コマンド (GPU 0-3、TP=1、4 プロセス)

```bash
for i in 0 1 2 3; do
  PORT=$((8100 + i))
  SC_PORT=$((5600 + i))
  CUDA_VISIBLE_DEVICES=$i \
  VLLM_NIXL_SIDE_CHANNEL_HOST=${NODE_IP} \
  VLLM_NIXL_SIDE_CHANNEL_PORT=${SC_PORT} \
  NCCL_SOCKET_IFNAME=^lo,docker,veth \
  GLOO_SOCKET_IFNAME=${IFACE} \
  FI_PROVIDER=efa \
  FI_EFA_USE_DEVICE_RDMA=1 \
  FI_EFA_FORK_SAFE=1 \
  NCCL_TIMEOUT=7200000 \
  TORCH_NCCL_HEARTBEAT_TIMEOUT_SEC=7200 \
  VLLM_WORKER_MULTIPROC_METHOD=spawn \
  VLLM_ENGINE_READY_TIMEOUT_S=14400 \
  TRITON_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/triton \
  FLASHINFER_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/flashinfer \
  VLLM_CACHE_ROOT=/mnt/k8s-disks/0/jit_cache/vllm \
  FLASH_ATTENTION_CUTE_DSL_CACHE_ENABLED=1 \
  FLASH_ATTENTION_CUTE_DSL_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/cute \
  NCCL_DEBUG=WARN \
  VLLM_NIXL_ABORT_REQUEST_TIMEOUT=480 \
  nohup vllm serve ${MODEL} \
    --tensor-parallel-size 1 \
    --quantization fp8 \
    --kv-cache-dtype fp8_e4m3 \
    --gpu-memory-utilization 0.90 \
    --max-model-len 32768 \
    --max-num-seqs 256 \
    --enable-chunked-prefill \
    --enforce-eager \
    --kv-transfer-config "${KV_CFG}" \
    --host 0.0.0.0 \
    --port ${PORT} \
    > /mnt/k8s-disks/0/pd-prefill-${i}.log 2>&1 &
  echo "prefill $i launched on port $PORT"
done
```

### Decode 起動コマンド (GPU 4-7、TP=1、4 プロセス)

```bash
for i in 0 1 2 3; do
  GPU=$((4 + i))
  PORT=$((8200 + i))
  SC_PORT=$((5610 + i))
  CUDA_VISIBLE_DEVICES=${GPU} \
  VLLM_NIXL_SIDE_CHANNEL_HOST=${NODE_IP} \
  VLLM_NIXL_SIDE_CHANNEL_PORT=${SC_PORT} \
  NCCL_SOCKET_IFNAME=^lo,docker,veth \
  GLOO_SOCKET_IFNAME=${IFACE} \
  FI_PROVIDER=efa \
  FI_EFA_USE_DEVICE_RDMA=1 \
  FI_EFA_FORK_SAFE=1 \
  NCCL_TIMEOUT=7200000 \
  TORCH_NCCL_HEARTBEAT_TIMEOUT_SEC=7200 \
  VLLM_WORKER_MULTIPROC_METHOD=spawn \
  VLLM_ENGINE_READY_TIMEOUT_S=14400 \
  TRITON_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/triton \
  FLASHINFER_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/flashinfer \
  VLLM_CACHE_ROOT=/mnt/k8s-disks/0/jit_cache/vllm \
  FLASH_ATTENTION_CUTE_DSL_CACHE_ENABLED=1 \
  FLASH_ATTENTION_CUTE_DSL_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/cute \
  NCCL_DEBUG=WARN \
  VLLM_NIXL_ABORT_REQUEST_TIMEOUT=480 \
  nohup vllm serve ${MODEL} \
    --tensor-parallel-size 1 \
    --quantization fp8 \
    --kv-cache-dtype fp8_e4m3 \
    --gpu-memory-utilization 0.90 \
    --max-model-len 32768 \
    --max-num-seqs 256 \
    --enable-chunked-prefill \
    --enforce-eager \
    --kv-transfer-config "${KV_CFG}" \
    --host 0.0.0.0 \
    --port ${PORT} \
    > /mnt/k8s-disks/0/pd-decode-${i}.log 2>&1 &
  echo "decode $i launched on GPU $GPU port $PORT"
done
```

注: `--enforce-eager` は smoke test 期間中は保持する。CUDA graphs が Gemma 4 PD 構成で問題ないと確認できたら外してよい。

### 全 8 ポート起動待ち

```bash
for port in 8100 8101 8102 8103 8200 8201 8202 8203; do
  echo -n "waiting port $port..."
  until curl -sf http://localhost:${port}/health >/dev/null 2>&1; do sleep 10; done
  echo " ready"
done
```

### Proxy 起動 (toy_proxy_server.py)

```bash
nohup python3 /opt/vllm/tests/v1/kv_connector/nixl_integration/toy_proxy_server.py \
  --host 0.0.0.0 \
  --port 9000 \
  --prefiller-hosts ${NODE_IP} ${NODE_IP} ${NODE_IP} ${NODE_IP} \
  --prefiller-ports 8100 8101 8102 8103 \
  --decoder-hosts ${NODE_IP} ${NODE_IP} ${NODE_IP} ${NODE_IP} \
  --decoder-ports 8200 8201 8202 8203 \
  > /mnt/k8s-disks/0/pd-proxy-4p4d.log 2>&1 &
```

[出所: `manifests/22-proxy-qwen3.yaml lines 63-66`, `manifests/40-dsv3-proxy.yaml lines 111-117`]

### 必須 env var 一覧と根拠

| 変数 | 値 | 根拠 |
|------|----|------|
| `NCCL_SOCKET_IFNAME` | `^lo,docker,veth` | 正方向指定は EFA を隠し TCP fallback で 28x 低速化。manifests全件に同パターン |
| `GLOO_SOCKET_IFNAME` | `$IFACE` (runtime) | `ip -o -4 addr show` で動的取得。静的値は hostNetwork pod で不正になる |
| `FI_PROVIDER=efa` | `efa` | LIBFABRIC の EFA プロバイダを強制。省略すると socket fallback |
| `FI_EFA_USE_DEVICE_RDMA` | `1` | GPUDirect RDMA over EFA 有効化 |
| `VLLM_NIXL_SIDE_CHANNEL_HOST` | `$NODE_IP` (runtime) | ZMQ handshake。`localhost` default では intra-node でも prefill/decode 間で疎通失敗する場合あり |
| `VLLM_NIXL_SIDE_CHANNEL_PORT` | P: 5600-5603, D: 5610-5613 | 同一ホストで 8 プロセス = ポート衝突を避けるため番号をずらす |
| `NCCL_TIMEOUT` | `7200000` | B300 JIT compile が数分かかる。タイムアウト切れ防止 |
| `VLLM_NIXL_ABORT_REQUEST_TIMEOUT` | `480` | P が KV をいつまでも保持しないよう上限を設定 |

[出所: `manifests/20-prefill-qwen3.yaml lines 60-79`, `RESEARCH.md section 2.3`, `RESEARCH.md section 2.4`]

---

## 3. GPU 割当 (公平 8-GPU 構成)

```
Node <NODE> (p6-b300.48xlarge, 8x B300 268 GiB)

GPU 0  -- prefill-0  TP=1  port 8100  side-channel 5600
GPU 1  -- prefill-1  TP=1  port 8101  side-channel 5601
GPU 2  -- prefill-2  TP=1  port 8102  side-channel 5602
GPU 3  -- prefill-3  TP=1  port 8103  side-channel 5603
GPU 4  -- decode-0   TP=1  port 8200  side-channel 5610
GPU 5  -- decode-1   TP=1  port 8201  side-channel 5611
GPU 6  -- decode-2   TP=1  port 8202  side-channel 5612
GPU 7  -- decode-3   TP=1  port 8203  side-channel 5613
                                                         
                     toy_proxy  port 9000 (no GPU)
```

DP baseline は `8x TP=1` だったので GPU 数は完全一致。TP=4 案は full_attention head-split リスク (4 heads / 8 ranks) と handshake 未検証のため採用しない。

[出所: `RUNLOG.md §9.1 baseline topology`, `DESIGN-v2-topology.md`]

---

## 4. 比較プロトコル

### DP baseline (参照値、lc-in30000.json / lc-in8192.json から取得済み)

| input | conc | goodput (req/s) | TTFT p90 (ms) | TPOT p90 (ms) | SLO |
|-------|------|----------------|--------------|--------------|-----|
| 1K    | 64   | 41.0           | -            | -            | -   |
| 8K    | 64   | 33.0           | 559          | 12.4         | 100% |
| 16K   | 64   | 25.0           | -            | -            | -   |
| 30K   | 64   | 16.7           | 2822         | 16.7         | 100% |

[出所: `results/lc-in30000.json`, `results/lc-in8192.json`, `RUNLOG.md §9.2`]

### PD sweep コマンド

**30K input (プライマリ)**:

```bash
python3 <repo>/scripts/concurrency_sweep.py \
  --base-url http://${NODE_IP}:9000/v1 \
  --model google/gemma-4-31b-it \
  --auth none \
  --input-tokens 30000 \
  --max-tokens 128 \
  --ignore-eos \
  --concurrency 16 32 64 96 128 192 256 \
  --requests-per-stage 200 \
  --slo-ttft-ms 5200 \
  --slo-tpot-ms 50 \
  --timeout 300 \
  --out results/pd-4p4d-in30000.json
```

**8K input (セカンダリ)**:

```bash
python3 <repo>/scripts/concurrency_sweep.py \
  --base-url http://${NODE_IP}:9000/v1 \
  --model google/gemma-4-31b-it \
  --auth none \
  --input-tokens 8192 \
  --max-tokens 128 \
  --ignore-eos \
  --concurrency 16 32 64 96 128 192 256 \
  --requests-per-stage 200 \
  --slo-ttft-ms 1200 \
  --slo-tpot-ms 50 \
  --timeout 300 \
  --out results/pd-4p4d-in8192.json
```

**SLO 設定根拠**: TTFT SLO = baseline p90 の 2x (余裕あり、PD は decode 側の queuing が減るため TTFT は baseline 以下になるはず)。TPOT SLO = 50ms (baseline の 3x)。

[出所: `scripts/concurrency_sweep.py lines 188-193`, `results/lc-in30000.json`, `results/lc-in8192.json`]

### 同一条件の確認チェックリスト

- model: `google/gemma-4-31b-it` (fp8 variant)、DP と同じ
- `--max-tokens 128 --ignore-eos`: DP baseline と同一
- `--requests-per-stage 200`: DP の 128 より多く、P90 信頼度向上
- tool use: DP baseline は tool なし、PD も tool なし (同条件)
- warmup: sweep 前に conc=4, 20 request の捨て走りを 1 回入れる (JIT キャッシュに NIXL shape を追加するため)

---

## 5. リスクと abort 基準

### リスク一覧

| リスク | 確信度 | abort 基準 |
|--------|--------|-----------|
| NixlConnector TransferTopology が heterogeneous KV spec で失敗 | MEDIUM | smoke request が HTTP 500 または prefill log に `TransferTopology` error / `NIXL compatibility check FAIL` が出たら即中止 |
| TP=8 full_attention head-split corruption (TP=1 採用で回避済) | LOW (TP=1なら N/A) | - |
| fp8 cache_dtype mismatch (P/D 片方だけ指定漏れ) | LOW | handshake log に `hash mismatch` → コマンド確認して再起動 |
| toy_proxy が 30K prefill (>2.6s) でタイムアウト | MEDIUM | proxy log に `timeout` / D が空応答 → VLLM_NIXL_ABORT_REQUEST_TIMEOUT=600 に延長 |
| sliding-window KV の D 側 partial transfer による decode corruption | MEDIUM | smoke response の文章が明らかに破綻している → PD not viable を記録 |
| intra-node LIBFABRIC が EFA を使わず shm fallback | LOW-MEDIUM | EFA tx_bytes カウンタが増加しない (probe 手順は §6 参照)。これは goodput に影響するだけで正確性は問題なし |

### "PD not viable" を記録すべき条件

- smoke test (1 request) が失敗し、ログに `NIXL` / `TransferTopology` エラーがある場合
- smoke test は通るが decode output が prompt と無関係な乱文になる場合 (sliding-window KV 破損の疑い)
- conc=64 で PD goodput が DP の 50% 未満かつ TTFT が DP より悪い場合 (proxy ボトルネック + model 非互換の複合)

[出所: `WORKLOG.md 'most important finding' section`, `RESEARCH.md section 2.4`]

---

## 6. 実行コマンド列 (Step by Step)

### Step 1: 既存 8 replica 停止 + GPU 全 PID kill

```bash
# vllm-8replica pod に exec
kubectl -n mt-serving exec -it vllm-8replica -- bash

# Step 1a: vllm serve プロセスを停止
pkill -f "vllm serve" 2>/dev/null
sleep 3

# Step 1b: EngineCore が GPU を掴んでいる残存プロセスを kill
# (重要: pkill だけでは EngineCore の子プロセスが残る)
nvidia-smi --query-compute-apps=pid --format=noheader,csv | xargs -r kill -9
sleep 5

# Step 1c: GPU が解放されたか確認
nvidia-smi --query-gpu=index,memory.used --format=noheader,csv
# 全 GPU が ~0 MiB になっていれば OK
```

[出所: `RUNLOG.md §9.4 kill sequence`]

### Step 2: Phase 0 Smoke Test (1P + 1D で Gate 確認)

```bash
# Step 2a: NODE_IP 取得
NODE_IP=$(hostname -I | awk '{print $1}')
IFACE=$(ip -o -4 addr show | grep "$NODE_IP" | awk '{print $2}' | head -1)
MODEL=google/gemma-4-31b-it
KV_CFG='{"kv_connector":"NixlConnector","kv_role":"kv_both","kv_load_failure_policy":"fail","kv_connector_extra_config":{"backends":["LIBFABRIC"]}}'

# Step 2b: prefill GPU 0、decode GPU 1 のみ起動
CUDA_VISIBLE_DEVICES=0 \
VLLM_NIXL_SIDE_CHANNEL_HOST=${NODE_IP} \
VLLM_NIXL_SIDE_CHANNEL_PORT=5600 \
NCCL_SOCKET_IFNAME=^lo,docker,veth \
GLOO_SOCKET_IFNAME=${IFACE} \
FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 FI_EFA_FORK_SAFE=1 \
NCCL_TIMEOUT=7200000 TORCH_NCCL_HEARTBEAT_TIMEOUT_SEC=7200 \
VLLM_WORKER_MULTIPROC_METHOD=spawn VLLM_ENGINE_READY_TIMEOUT_S=14400 \
TRITON_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/triton \
FLASHINFER_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/flashinfer \
VLLM_CACHE_ROOT=/mnt/k8s-disks/0/jit_cache/vllm \
FLASH_ATTENTION_CUTE_DSL_CACHE_ENABLED=1 \
FLASH_ATTENTION_CUTE_DSL_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/cute \
NCCL_DEBUG=WARN VLLM_NIXL_ABORT_REQUEST_TIMEOUT=480 \
nohup vllm serve ${MODEL} \
  --tensor-parallel-size 1 --quantization fp8 --kv-cache-dtype fp8_e4m3 \
  --gpu-memory-utilization 0.90 --max-model-len 32768 --max-num-seqs 256 \
  --enable-chunked-prefill --enforce-eager \
  --kv-transfer-config "${KV_CFG}" --host 0.0.0.0 --port 8100 \
  > /mnt/k8s-disks/0/pd-prefill-0.log 2>&1 &

CUDA_VISIBLE_DEVICES=1 \
VLLM_NIXL_SIDE_CHANNEL_HOST=${NODE_IP} \
VLLM_NIXL_SIDE_CHANNEL_PORT=5601 \
NCCL_SOCKET_IFNAME=^lo,docker,veth \
GLOO_SOCKET_IFNAME=${IFACE} \
FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 FI_EFA_FORK_SAFE=1 \
NCCL_TIMEOUT=7200000 TORCH_NCCL_HEARTBEAT_TIMEOUT_SEC=7200 \
VLLM_WORKER_MULTIPROC_METHOD=spawn VLLM_ENGINE_READY_TIMEOUT_S=14400 \
TRITON_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/triton \
FLASHINFER_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/flashinfer \
VLLM_CACHE_ROOT=/mnt/k8s-disks/0/jit_cache/vllm \
FLASH_ATTENTION_CUTE_DSL_CACHE_ENABLED=1 \
FLASH_ATTENTION_CUTE_DSL_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/cute \
NCCL_DEBUG=WARN VLLM_NIXL_ABORT_REQUEST_TIMEOUT=480 \
nohup vllm serve ${MODEL} \
  --tensor-parallel-size 1 --quantization fp8 --kv-cache-dtype fp8_e4m3 \
  --gpu-memory-utilization 0.90 --max-model-len 32768 --max-num-seqs 256 \
  --enable-chunked-prefill --enforce-eager \
  --kv-transfer-config "${KV_CFG}" --host 0.0.0.0 --port 8200 \
  > /mnt/k8s-disks/0/pd-decode-0.log 2>&1 &

# Step 2c: 起動待ち
until curl -sf http://localhost:8100/health >/dev/null 2>&1; do sleep 10; done; echo "prefill ready"
until curl -sf http://localhost:8200/health >/dev/null 2>&1; do sleep 10; done; echo "decode ready"

# Step 2d: proxy 起動
nohup python3 /opt/vllm/tests/v1/kv_connector/nixl_integration/toy_proxy_server.py \
  --host 0.0.0.0 --port 9000 \
  --prefiller-hosts ${NODE_IP} --prefiller-ports 8100 \
  --decoder-hosts ${NODE_IP} --decoder-ports 8200 \
  > /mnt/k8s-disks/0/pd-proxy-smoke.log 2>&1 &
sleep 15

# Step 2e: GATE チェック (1)
grep -c "NIXL compatibility check passed" /mnt/k8s-disks/0/pd-decode-0.log || echo "ABORT: compatibility check not found"
grep "TransferTopology" /mnt/k8s-disks/0/pd-decode-0.log | head -3

# Step 2f: GATE チェック (2) smoke request
curl -s http://localhost:9000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"google/gemma-4-31b-it","prompt":"The capital of France is","max_tokens":10}'
# レスポンスに意味のある text が返れば GREEN

# Step 2g: EFA KV transfer 確認 (intra-node では shm fallback の可能性あり、goodput 影響のみ)
BEFORE=$(cat /sys/class/infiniband/*/ports/1/hw_counters/tx_bytes 2>/dev/null | paste -sd+ | bc)
# smoke request を 5 回投げてから
AFTER=$(cat /sys/class/infiniband/*/ports/1/hw_counters/tx_bytes 2>/dev/null | paste -sd+ | bc)
echo "EFA tx_bytes delta: $((AFTER - BEFORE)) bytes"
```

**ABORT 判定**: `compatibility check passed` が 0 件、または curl が HTTP 5xx、または text が乱文 → `PD not viable for Gemma 4 on vLLM 0.21` を結論として記録し以下を実行しない。

### Step 3: Smoke 成功後、4P + 4D フル起動

```bash
# Step 3a: smoke プロセス停止
pkill -f "vllm serve" 2>/dev/null; pkill -f toy_proxy 2>/dev/null
sleep 3
nvidia-smi --query-compute-apps=pid --format=noheader,csv | xargs -r kill -9
sleep 5

# Step 3b: 4 prefill workers (GPUs 0-3)
for i in 0 1 2 3; do
  PORT=$((8100 + i)); SC_PORT=$((5600 + i))
  CUDA_VISIBLE_DEVICES=$i \
  VLLM_NIXL_SIDE_CHANNEL_HOST=${NODE_IP} VLLM_NIXL_SIDE_CHANNEL_PORT=${SC_PORT} \
  NCCL_SOCKET_IFNAME=^lo,docker,veth GLOO_SOCKET_IFNAME=${IFACE} \
  FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 FI_EFA_FORK_SAFE=1 \
  NCCL_TIMEOUT=7200000 TORCH_NCCL_HEARTBEAT_TIMEOUT_SEC=7200 \
  VLLM_WORKER_MULTIPROC_METHOD=spawn VLLM_ENGINE_READY_TIMEOUT_S=14400 \
  TRITON_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/triton \
  FLASHINFER_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/flashinfer \
  VLLM_CACHE_ROOT=/mnt/k8s-disks/0/jit_cache/vllm \
  FLASH_ATTENTION_CUTE_DSL_CACHE_ENABLED=1 \
  FLASH_ATTENTION_CUTE_DSL_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/cute \
  NCCL_DEBUG=WARN VLLM_NIXL_ABORT_REQUEST_TIMEOUT=480 \
  nohup vllm serve ${MODEL} \
    --tensor-parallel-size 1 --quantization fp8 --kv-cache-dtype fp8_e4m3 \
    --gpu-memory-utilization 0.90 --max-model-len 32768 --max-num-seqs 256 \
    --enable-chunked-prefill --enforce-eager \
    --kv-transfer-config "${KV_CFG}" --host 0.0.0.0 --port ${PORT} \
    > /mnt/k8s-disks/0/pd-prefill-${i}.log 2>&1 &
done

# Step 3c: 4 decode workers (GPUs 4-7)
for i in 0 1 2 3; do
  GPU=$((4 + i)); PORT=$((8200 + i)); SC_PORT=$((5610 + i))
  CUDA_VISIBLE_DEVICES=${GPU} \
  VLLM_NIXL_SIDE_CHANNEL_HOST=${NODE_IP} VLLM_NIXL_SIDE_CHANNEL_PORT=${SC_PORT} \
  NCCL_SOCKET_IFNAME=^lo,docker,veth GLOO_SOCKET_IFNAME=${IFACE} \
  FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 FI_EFA_FORK_SAFE=1 \
  NCCL_TIMEOUT=7200000 TORCH_NCCL_HEARTBEAT_TIMEOUT_SEC=7200 \
  VLLM_WORKER_MULTIPROC_METHOD=spawn VLLM_ENGINE_READY_TIMEOUT_S=14400 \
  TRITON_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/triton \
  FLASHINFER_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/flashinfer \
  VLLM_CACHE_ROOT=/mnt/k8s-disks/0/jit_cache/vllm \
  FLASH_ATTENTION_CUTE_DSL_CACHE_ENABLED=1 \
  FLASH_ATTENTION_CUTE_DSL_CACHE_DIR=/mnt/k8s-disks/0/jit_cache/cute \
  NCCL_DEBUG=WARN VLLM_NIXL_ABORT_REQUEST_TIMEOUT=480 \
  nohup vllm serve ${MODEL} \
    --tensor-parallel-size 1 --quantization fp8 --kv-cache-dtype fp8_e4m3 \
    --gpu-memory-utilization 0.90 --max-model-len 32768 --max-num-seqs 256 \
    --enable-chunked-prefill --enforce-eager \
    --kv-transfer-config "${KV_CFG}" --host 0.0.0.0 --port ${PORT} \
    > /mnt/k8s-disks/0/pd-decode-${i}.log 2>&1 &
done

# Step 3d: 全 8 ポート起動待ち
for port in 8100 8101 8102 8103 8200 8201 8202 8203; do
  echo -n "waiting $port..."
  until curl -sf http://localhost:${port}/health >/dev/null 2>&1; do sleep 10; done
  echo " ok"
done

# Step 3e: 4P+4D proxy 起動
nohup python3 /opt/vllm/tests/v1/kv_connector/nixl_integration/toy_proxy_server.py \
  --host 0.0.0.0 --port 9000 \
  --prefiller-hosts ${NODE_IP} ${NODE_IP} ${NODE_IP} ${NODE_IP} \
  --prefiller-ports 8100 8101 8102 8103 \
  --decoder-hosts ${NODE_IP} ${NODE_IP} ${NODE_IP} ${NODE_IP} \
  --decoder-ports 8200 8201 8202 8203 \
  > /mnt/k8s-disks/0/pd-proxy-4p4d.log 2>&1 &
echo "proxy up on :9000"
```

### Step 4: warmup (JIT cache に NIXL shape を追加)

```bash
# conc=4, 20 requests、結果は捨て
python3 <repo>/scripts/concurrency_sweep.py \
  --base-url http://${NODE_IP}:9000/v1 \
  --model google/gemma-4-31b-it --auth none \
  --input-tokens 30000 --max-tokens 128 --ignore-eos \
  --concurrency 4 --requests-per-stage 20 \
  --out /dev/null
```

### Step 5: 本番 sweep

Step 4 完了後、§4 の sweep コマンドを実行する。結果は:

- `results/pd-4p4d-in30000.json`
- `results/pd-4p4d-in8192.json`

### Step 6: DP baseline に戻す (sweep 完了後)

```bash
pkill -f "vllm serve" 2>/dev/null; pkill -f toy_proxy 2>/dev/null
sleep 3
nvidia-smi --query-compute-apps=pid --format=noheader,csv | xargs -r kill -9
sleep 5

# 8 replica 再起動 (既存 manifest を apply)
kubectl -n mt-serving apply -f \
  <repo>/manifests/10-vllm-8replica-gemma4-31b.yaml
```

---

## 低確信事項の明示

以下は確信度が MEDIUM 以下の点:

1. **intra-node LIBFABRIC の実際の transport path**: B300 同一ノードで LIBFABRIC を指定したとき EFA を使うか NVLink 経由の shm/cuda_ipc を使うかは未確認。EFA byte counter が増加しない場合は shm を使っている。goodput への影響はあるが correctness は問題ない。UCX backend に切り替える場合は `"backends":["UCX"]` + `UCX_TLS=sm,cuda_ipc,rc` に変更する。

2. **VLLM_NIXL_SIDE_CHANNEL_PORT の intra-node 衝突**: 8 プロセス全員が hostNetwork で同一 IP を持つ。5600-5603 (P) / 5610-5613 (D) で番号をずらしているが、toy_proxy が decode の side-channel port を正しく解決するか (proxy は prefiller の side-channel port を直接叩かず、vllm serve の kv_transfer_params で渡された remote_port を使う) は probe が必要。ZMQ の bind は各プロセス自身が行うため衝突は起きないはずだが、D -> P への初期接続が `VLLM_NIXL_SIDE_CHANNEL_HOST:5600-5603` のどれを使うかは decode プロセス数と port の対応で決まる。smoke test のログで "side channel connected to" を確認すること。

3. **Gemma 4 fp8 の正確な model path**: `google/gemma-4-31b-it` は HuggingFace の gated model。既存の `vllm-8replica` pod が使っているローカルパス (`/mnt/k8s-disks/0/models/...`) を `kubectl exec ... -- ls /mnt/k8s-disks/0/models/` で確認して `MODEL=` を差し替えること。`RUNLOG.md` の記述から model は `/mnt/k8s-disks/0` 以下にある可能性が高い。