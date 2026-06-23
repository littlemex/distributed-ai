# llm-d / GIE EndpointPicker による LoRA-aware routing 実験

Gemma 4 31B (fp8) を **8 個の独立 Pod (1 Pod = 1 GPU = 1 vLLM)** で起動し、
[Gateway API Inference Extension (GIE)](https://github.com/kubernetes-sigs/gateway-api-inference-extension)
v1.5.0 の EndpointPicker (EPP) によるルーティングを計測する。
EPP の scheduling profile を差し替えるだけで、同一の 8 Pod・同一の EPP 経路で
複数のルーティング戦略を公平に比較できる。

## なぜこの構成か (前回計測との整合性)

親ディレクトリの計測 (`../results/B-*.json`) は **1 Pod の中で 8 個の vLLM プロセス
(port 8000-8007) を起動**し、ベンチ側 (`concurrency_sweep.py`) が
`--base-url` のカンマ区切り 8 URL を client-side で roundrobin / affinity していた。

llm-d の EPP は **Pod 単位**で endpoint を束ねて routing する。そこで構成を
「1 Pod 8 プロセス」から「8 Pod」へ変えるが、**この変更が TTFT/TPOT/Goodput を
変えてはいけない** (登壇は一貫した 1 つの実験として行うため)。これを担保するのが
整合性検証 (下記 `direct-rr` / `direct-affinity`) であり、前回値との一致を
`compare_integrity.py` で確認する。

## 構成図

```
                       (同一ノード <NODE>, 8 GPU)
 mt-lora-bench Pod                              mt-lora-pool (Deployment, replicas=8)
 (concurrency_sweep.py) ──┐                     ┌─ Pod0 vLLM :8000 (GPU0) adapter-0..127
                          │  EPP 経由           ├─ Pod1 vLLM :8000 (GPU1) adapter-0..127
   http://mt-lora-epp:80 ─┤                     ├─ ...
        │                 │                     └─ Pod7 vLLM :8000 (GPU7) adapter-0..127
        ▼                 │                              ▲
   Envoy sidecar :8081 ───┘                              │ x-gateway-destination-endpoint
        │ ext_proc gRPC                                  │ で選ばれた Pod IP:8000 へ
        ▼                                                │
   EPP scheduler :9002 ── InferencePool(mt-lora-pool) ───┘
   (profile: rr / affinity / full)   selector app=mt-lora-pool, targetPort 8000
```

direct-rr / direct-affinity は EPP/Envoy を通さず、bench Pod が 8 Pod IP を直接叩く
(前回 1Pod8proc の client-side routing と同じ仕組みを 8 Pod に当てたもの)。

## 計測する条件 (5 つ)

| condition | 経路 | routing 決定 | 目的 |
|---|---|---|---|
| `direct-rr` | 8 Pod IP 直接 | client roundrobin (req 循環) | 前回 `B-roundrobin.json` との整合性 |
| `direct-affinity` | 8 Pod IP 直接 | client 静的シャード (`adapter%8`) | 前回 `B-affinity.json` との整合性 |
| `epp-rr` | Envoy→EPP | random-picker | EPP 経路自体が中立か |
| `epp-affinity` | Envoy→EPP | lora-affinity-scorer | LoRA-aware routing 単独効果 |
| `epp-full` | Envoy→EPP | queue+kv+prefix+lora-affinity | llm-d 代表構成 |

ワークロードは全条件で前回と完全一致:
`adapters=128, zipf=1.1, concurrency=[8,32,64,128,256,512], requests_per_stage=512,
max_tokens=64, ignore_eos, SLO ttft<=2000ms / tpot<=80ms`。

## 再現手順

前提: `kubectl` が EKS `<EKS_CLUSTER>` に通っていること
(`aws eks update-kubeconfig --name <EKS_CLUSTER> --region us-west-2`)。
namespace `mt-serving`、ECR pull secret `ecr-pull-secret`、HF token secret `hf-token` が存在すること。

```bash
cd llm-d

# 1. 8 Pod vLLM + LoRA adapter 生成・登録
kubectl apply -f manifests/20-vllm-pool-gemma4-31b.yaml
kubectl rollout status deploy/mt-lora-pool -n mt-serving --timeout=600s
#    adapter 生成 (1 Pod で 1 回。hostPath 共有なので全 Pod から見える)
POD=$(kubectl get pods -n mt-serving -l app=mt-lora-pool -o name | head -1 | sed 's|pod/||')
kubectl cp ../scripts/synth_dummy_lora.py     mt-serving/$POD:/tmp/
kubectl cp ../scripts/register_adapters.sh    mt-serving/$POD:/tmp/
kubectl exec $POD -n mt-serving -- python3 /tmp/synth_dummy_lora.py \
   --n 128 --out-dir /mnt/k8s-disks/0/adapters/gemma4-31b --rank 16 --config-json <gemma4-cfg>
#    各 Pod に adapter 0-127 を登録 (register_adapters.sh は逐次推奨。並列だと engine が詰まる)
for P in $(kubectl get pods -n mt-serving -l app=mt-lora-pool -o name|sed 's|pod/||'); do
  kubectl cp ../scripts/register_adapters.sh mt-serving/$P:/tmp/
  kubectl exec $P -n mt-serving -- bash -lc \
    'nohup bash /tmp/register_adapters.sh /mnt/k8s-disks/0/adapters/gemma4-31b 128 8000 >/tmp/reg.log 2>&1 &'
done

# 2. EPP スタック (RBAC / Envoy CM / InferencePool / EPP Deployment / bench Pod)
kubectl apply -f manifests/10-rbac-epp.yaml
kubectl apply -f manifests/40-envoy-configmap.yaml
kubectl apply -f manifests/30-inferencepool-epp.yaml
kubectl apply -f manifests/60-bench-client.yaml
./switch_profile.sh rr              # 初期 profile を作って EPP Deployment を起動
kubectl apply -f manifests/50-epp-deployment.yaml

# 3. 全条件を計測 (結果は llm-d/results/llmd-*.json に保存)
./run_experiment.sh

# 4. 整合性検証 (前回値と新構成値の差分)
python3 compare_integrity.py
```

## ファイル

```
llm-d/
├── README.md                  # 本ファイル
├── manifests/
│   ├── 10-rbac-epp.yaml            # EPP の SA + Role/RoleBinding
│   ├── 20-vllm-pool-gemma4-31b.yaml# 8 Pod vLLM Deployment + headless Service
│   ├── 30-inferencepool-epp.yaml   # InferencePool + EPP Service
│   ├── 40-envoy-configmap.yaml     # Envoy sidecar 設定 (ext_proc→ORIGINAL_DST)
│   ├── 50-epp-deployment.yaml      # EPP Deployment (envoy + scheduler 2 コンテナ)
│   └── 60-bench-client.yaml        # 同一ノードのベンチ実行 Pod
├── epp-configs/
│   ├── profile-rr.yaml             # random-picker のみ
│   ├── profile-affinity.yaml       # lora-affinity-scorer のみ
│   └── profile-full.yaml           # queue+kv+prefix+lora-affinity
├── switch_profile.sh          # profile 差し替え + EPP rollout restart
├── run_experiment.sh          # 5 条件を同一 sweep で計測するオーケストレータ
└── compare_integrity.py       # 前回値 (../results/B-*.json) との差分検証
```
