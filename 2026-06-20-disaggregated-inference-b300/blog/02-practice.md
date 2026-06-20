---
title: "Disaggregated Inference 実践編 ― EKS + B300 で vLLM/NIXL/llm-d を動かす"
emoji: "🛠️"
type: "tech"
topics: ["LLM", "vLLM", "Kubernetes", "EKS", "llmd"]
published: false
---

## この記事について

[理論編](./01-theory.md) で解説した Disaggregated Inference を、**Amazon EKS 上の NVIDIA B300 GPU で実際に動かす**ための実践ガイドです。構築手順、最新世代 GPU 特有のハマりどころ、実際に使ったコードを解説します。

実装一式は [github.com/littlemex/distributed-inference](https://github.com/littlemex/distributed-inference) の `2026-06-20-disaggregated-inference-b300/` にあります。

:::message alert
本記事は特定の借用クラスタ（EKS 1.35 + p6-b300）での実体験に基づきます。インスタンスタイプ名・taint・ストレージパスなどはクラスタ固有なので、自分の環境に合わせて読み替えてください。
:::

### 全体の流れ

```
0. 前提環境の確認
1. コンテナイメージのビルド（B300 = sm_103 対応）
2. vLLM native で分離推論を動かす（土台）
3. llm-d で賢いルーティングを載せる
4. ベンチマーク（goodput 計測）
5. 後片付け
```

---

## 0. 前提環境

| 項目 | 値 |
| --- | --- |
| Kubernetes | EKS 1.35 |
| GPU | p6-b300.48xlarge（NVIDIA B300, Blackwell **sm_103**, 8 GPU/node, EFA 16/node） |
| ストレージ | 各ノードの instance NVMe `/mnt/k8s-disks/0`（モデル・キャッシュ置き場） |
| GPUDirect | `/dev/gdrdrv` がノードに用意済み（DaemonSet で提供） |

GPU ノードには複数の **taint** が付いており、Pod 側に対応する toleration が必須です。

```yaml
tolerations:
  - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
  - { key: vpc.amazonaws.com/efa, operator: Exists, effect: NoSchedule }
  - { key: workload, operator: Equal, value: bench, effect: NoSchedule }
  - { key: capacity-reservation, operator: Exists, effect: NoSchedule }   # 値は予約ごとに変わるので Exists
  - { key: sagemaker.amazonaws.com/node-health-status, operator: Equal, value: Schedulable, effect: NoSchedule }
```

:::message
`capacity-reservation` の値は予約のたびに変わります。固定値で書くと別の予約に切り替わったときに動かなくなるので、必ず `operator: Exists` で吸収します。
:::

実験用の namespace を切ります（借用クラスタなので他人と混ざらないよう自分専用に）。

```bash
kubectl create namespace akazawt-disagg
```

---

## 1. コンテナイメージのビルド ― sm_103 の壁

最初の関門が**イメージ**です。B300 は Blackwell 世代の `sm_103` という新しい compute capability を持ち、**既製の vLLM イメージの多くがこれに対応していません**。vLLM・NIXL・UCCL を `sm_103` + CUDA 13 向けに**ソースからビルド**する必要があります。

ビルドの要点（Dockerfile は `setup/Dockerfile.vllm-uccl-nixl`）:

- `TORCH_CUDA_ARCH_LIST` に `10.3`（sm_103）を含める
- CUDA 13 / NIXL の cu13 wheel を使う
- EFA installer・NCCL・GDRCopy を同梱

### ハマりどころ 1-A: rootless BuildKit では EFA installer の展開に失敗する

ビルドを Kubernetes Job で回す際、最初に **rootless BuildKit** を使ったところ、EFA installer の tarball 展開で失敗しました。

```
tar: aws-efa-installer/efa_installer.sh: Cannot change ownership to uid 88806, gid 100: Invalid argument
```

rootless モードは user namespace 内で UID マッピングが制限され、tar が所有者情報を復元できないためです。**privileged な（非 rootless の）BuildKit に切り替える**ことで解決します（Dockerfile は変更不要）。

```yaml
# manifests/10-buildkit-job.yaml の要点
image: moby/buildkit:v0.18.2      # rootless ではない版
securityContext:
  privileged: true                 # tar の chown が通る
command: ["sh","-c","buildkitd & ... buildctl build ..."]
```

:::message
`--mount=type=cache` を使う Dockerfile は **Kaniko では正しくビルドできません**（cache mount を無視する + wheel の mtime 固定で snapshot をスキップするバグ）。BuildKit を使ってください。
:::

ビルドは GPU を使わない（ビルド時のスモークテストは import チェックのみ）ので、CPU の多い B300 ノードを一時的に1台使うと速いです（`MAX_JOBS` が効く）。完成したイメージは自分の ECR に push します。

### ハマりどころ 1-B: ビルドドリフト（古い OSS を今ビルドすると壊れる）

vLLM 0.21.0 のような「少し前のリリース」を**今**ビルドすると、依存ライブラリが最新版に浮いて壊れることがあります。実際に踏んだのがこれです。

vLLM 0.21.0 は `fastapi >= 0.115.0`（下限のみ）と指定しているため、ビルド時に最新の fastapi 0.137 が入ります。ところが fastapi 0.137 で `include_router` の内部実装が変わり（`_IncludedRouter` という `.path` を持たないルート型が導入された）、これに `prometheus-fastapi-instrumentator` が未対応で、**全 HTTP リクエストが 500 エラー**になりました。

```
AttributeError: '_IncludedRouter' object has no attribute 'path'
```

推論エンジン自体は正常起動しているのに、API サーバーが全部 500 を返すという厄介な症状です。対策は**リリース当時の依存バージョンにピン**することです。

```dockerfile
# Dockerfile に追記（vLLM インストール直後）
RUN pip install "fastapi[standard]==0.116.0" \
                "prometheus-fastapi-instrumentator==7.1.0"
```

fastapi 0.116.0 は starlette を `< 0.47` に固定するため、問題の `_IncludedRouter` を持ち込みません。

:::message
教訓: **OSS の特定リリースを後日ビルドするときは、リリース時点の依存バージョンに合わせてピンする**。下限のみの指定（`>=`）は時限爆弾になりえます。
:::

---

## 2. vLLM native で分離推論を動かす（土台）

まず llm-d を使わず、vLLM 標準の構成で「prefill / decode を分離して KV キャッシュを EFA 経由で転送する」土台を作ります。これが動けば、要素技術（NIXL / EFA）の足回りが正しいと確認できます。

構成は **prefill 1 Pod + decode 1 Pod + proxy 1 Pod**（`manifests/20〜22-*.yaml`）。各 Pod の重要設定を解説します。

### 2.1 EFA / hostNetwork / GPUDirect

```yaml
spec:
  hostNetwork: true                      # EFA をフル帯域で使うのに必須
  dnsPolicy: ClusterFirstWithHostNet
  containers:
    - securityContext: { privileged: true }
      resources:
        limits: { nvidia.com/gpu: "8", vpc.amazonaws.com/efa: "16" }
      volumeMounts:
        - { name: gdrdrv, mountPath: /dev/gdrdrv }
  volumes:
    - { name: gdrdrv, hostPath: { path: /dev/gdrdrv, type: CharDevice } }
```

### 2.2 NCCL を EFA に乗せる（性能に直結する罠）

最も重要な設定です。NCCL のネットワークインターフェース選択を**除外パターン**で書きます。

```yaml
env:
  - { name: FI_PROVIDER, value: "efa" }
  - { name: FI_EFA_USE_DEVICE_RDMA, value: "1" }
  - { name: NCCL_SOCKET_IFNAME, value: "^lo,docker,veth" }   # 先頭の ^ が「除外」
```

:::message alert
`NCCL_SOCKET_IFNAME` を `eth0` のように**肯定形で指定すると EFA が見えなくなり、TCP にフォールバックして約 28 倍遅くなります**。必ず `^lo,docker,veth`（lo/docker/veth を除外＝EFA を残す）の形で書きます。
:::

起動後、Pod 内で `fi_info -p efa` が provider を返せば EFA が認識されています。

### 2.3 JIT キャッシュの永続化（B300「40倍遅い」の正体）

B300（sm_103）では、DeepGEMM / Triton / CuTe といったカーネルが**入力テンソルの形（shape）ごとに JIT コンパイル**されます。これが**推論リクエストの処理中に走る**と、TTFT が数十秒に跳ね上がります。「B300 が異常に遅い」と見える主因はこれです。

対策は、JIT キャッシュをノードの NVMe に**永続化**し、各 shape のコンパイルを「一度きり」にすることです。

```yaml
env:
  - { name: HF_HOME, value: /mnt/k8s-disks/0/local_scratch/hf_cache }
  - { name: TRITON_CACHE_DIR, value: /mnt/k8s-disks/0/jit_cache/triton }
  - { name: FLASHINFER_CACHE_DIR, value: /mnt/k8s-disks/0/jit_cache/flashinfer }
  - { name: VLLM_CACHE_ROOT, value: /mnt/k8s-disks/0/jit_cache/vllm }
```

### 2.4 NixlConnector の設定

prefill / decode 両方の vLLM に、KV コネクタとして NIXL を libfabric（EFA）バックエンドで指定します。

```bash
vllm serve <model> --tensor-parallel-size 8 \
  --kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both",
    "kv_connector_extra_config":{"backends":["LIBFABRIC"]}}' \
  --host 0.0.0.0 --port 8100   # decode は 8200
```

### 2.5 動作確認 ― KV キャッシュが本当に EFA を通っているか

「動いた」だけでなく、**KV キャッシュが本当に EFA を流れているか**を実測で確認するのが大切です（NVLink で完結していて EFA を使っていない、という落とし穴がある）。EFA のバイトカウンタを推論の前後で比較します。

```bash
# Pod 内で（推論前後に実行して差分を見る）
cat /sys/class/infiniband/*/ports/1/hw_counters/tx_bytes
```

推論をかけた前後でこの値が増えていれば、KV キャッシュが EFA を通って転送されている証拠です。実際に、大きめのプロンプトを数回投げた前後で約 16 MB の増加を観測できました。

---

## 3. llm-d で賢いルーティングを載せる

土台ができたら、その上に llm-d（EPP による賢いルーティング）を載せます。借用クラスタには Gateway 系の CRD が何も入っていない状態からのスタートでした。

### 3.1 GIE の CRD を入れる

```bash
kubectl apply -k "https://github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd?ref=v1.5.0"
```

### 3.2 llm-d Router を Standalone モードでデプロイ

llm-d には Kubernetes Gateway を立てる「Gateway モード」と、Envoy サイドカーだけで完結する「Standalone モード」があります。借用クラスタへの侵襲を最小にするため **Standalone モード**を選びました。

```bash
helm install pd-disaggregation \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/standalone \
  -f guides/recipes/scheduler/base.values.yaml \
  -f guides/pd-disaggregation/scheduler/pd-disaggregation.values.yaml \
  -n akazawt-disagg --version v1.5.0
```

### ハマりどころ 3-A: EPP が Pending になる（CPU 不足 + taint）

EPP の Pod は GPU を使いませんが、Envoy + EPP で CPU を 8 要求します。借用クラスタの CPU ノードは小さく（4 vCPU）、かといって GPU ノードは taint で弾かれて、Pod が Pending になりました。

解決策は、**EPP を GPU ノードに同居させる**（GPU は消費しない）こと。helm の values で toleration を追加します（`llm-d/epp-b300-tolerations.values.yaml`）。

```yaml
inferenceExtension:
  tolerations:
    - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
    - { key: workload, operator: Equal, value: bench, effect: NoSchedule }
    - { key: capacity-reservation, operator: Exists, effect: NoSchedule }
    - { key: sagemaker.amazonaws.com/node-health-status, operator: Equal, value: Schedulable, effect: NoSchedule }
```

### 3.3 モデルサーバーを B300 向けにカスタマイズ

llm-d は kustomize の overlay でモデルサーバーを定義します。公式の汎用 GPU overlay には B300 + EFA の設定（hostNetwork、EFA リソース、taint、JIT キャッシュ、自前イメージ）が無いので、それらを patch で追加した overlay を自作します（`llm-d/modelserver-qwen3-b300/`、`llm-d/modelserver-dsv3-b300/`）。

```yaml
# kustomization.yaml の要点: 公式 base を継承し、自前イメージに差し替え
resources:
  - ../base
images:
  - name: docker.io/vllm/vllm-openai
    newName: <自分のECR>/vllm-uccl-ep
    newTag: vllm0.21.0-uccl-0dc87eb-cu13-b300-fix1
patches:
  - { path: patch-prefill-b300.yaml, target: { kind: Deployment, name: prefill } }
  - { path: patch-decode-b300.yaml, target: { kind: Deployment, name: decode } }
```

### ハマりどころ 3-B: kustomize は絶対パスの resources を許さない

overlay の `resources` に公式 base を絶対パスで指定すると、kustomize がエラーになります（セキュリティ制約）。**overlay を llm-d リポジトリ内に置き、相対パス（`../base`）で参照**する必要があります。

デプロイ:

```bash
kubectl apply -n akazawt-disagg -k <overlay ディレクトリ>
```

llm-d では decode Pod に **routing-sidecar** が自動で挿入され、リクエストは「EPP → sidecar → prefill/decode」と流れます。EPP の ClusterIP に推論リクエストを投げて動作確認します。

```bash
IP=$(kubectl get service pd-disaggregation-epp -n akazawt-disagg -o jsonpath='{.spec.clusterIP}')
curl -X POST http://$IP/v1/completions -H 'Content-Type: application/json' \
  -d '{"model":"<model>","prompt":"The capital of France is","max_tokens":24}'
```

---

## 4. ベンチマーク（goodput 計測）

理論編で説明した goodput を計測します。`vllm bench serve` で各リクエストレートを Poisson 分布で投げ、P90 TTFT / P90 TPOT / スループットを記録し、両 SLO を満たす最大レートを求めます。

計測クライアントは GPU 不要の Pod（`manifests/30-benchcli.yaml`）として立て、proxy または EPP のエンドポイントを叩きます。

### ハマりどころ 4-A: cold-JIT による単発レイテンシの暴騰

ベンチの最初に「単発リクエストのレイテンシ」を測って SLO の基準にする手法がありますが、B300 では**この単発リクエストが JIT コンパイルを踏んで TTFT が 17 秒**になることがありました（2.3 の JIT 問題）。

対策:
- 各レートの計測前に **warmup（捨て打ち）** を入れて JIT を済ませてから本計測する
- arm（比較対象）ごとに別々の SLO で評価せず、**共通の絶対 SLO** で評価する（cold-JIT を踏んだ arm の基準が緩くなるのを防ぐ）

### ハマりどころ 4-B: Pod から S3 へ直接書けない（cross-account）

計測データを保存しようとして、Pod 内から `aws s3 cp` したところ AccessDenied になりました。借用クラスタのノード IAM ロールは別アカウントで、こちらの S3 への権限が無いためです（バケットポリシーで許可しても、IAM ロール側の権限が無いと cross-account では通らない）。

解決策は **`Pod 内 → kubectl cp → ローカル（自分の認証）→ aws s3` の経路**でデータを吸い出すことです（`recipe/collect-to-s3.sh`）。

```bash
# Pod 内の /results を kubectl cp でローカルへ → S3 へ sync
kubectl cp <pod>:/results <local> -c <container>
aws s3 sync <local> s3://<your-bucket>/<path>/
```

### 計測の比較設計 ― TP を揃える

native と llm-d を比較するとき、**並列度（Tensor Parallel）を揃える**ことが決定的に重要です。当初 native を TP4/DP2、llm-d を TP8/DP1 で測ってしまい、「llm-d が速い」と見えましたが、これは TP の違いによる交絡でした。**両方を TP8/DP1 に揃えて測り直す**ことで、初めて公平な比較になります。

理論編の図3〜4で示した結果は、すべて同一 TP（=8）での比較です。

---

## 5. 後片付け（借用クラスタの作法）

GPU は貴重な共有資源なので、計測が終わったら速やかに解放します。

```bash
# GPU を使う Deployment / Pod を削除
kubectl -n akazawt-disagg delete deployment --all
helm -n akazawt-disagg uninstall pd-disaggregation

# 自分が入れた CRD は撤収時に削除（クラスタ全体に残るため）
kubectl delete -k "https://github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd?ref=v1.5.0"

# GPU 解放を確認（出力が空ならゼロ）
kubectl get pods -A -o json | jq -r '.items[]
  | select(.status.phase=="Running")
  | select([.spec.containers[].resources.requests."nvidia.com/gpu"//"0"]|map(tonumber)|add>0)
  | .metadata.name'
```

namespace 自体・自前 ECR イメージ・S3 のデータは（GPU を消費しないので）次の実験のために残してよいでしょう。

---

## ハマりどころ早見表

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| Pod が Pending（taint） | toleration 不足 | §0 の 5 taint を全部付ける |
| Pod が Pending（CPU 不足） | CPU ノードが小さい | GPU ノードに toleration 付きで同居 |
| 通信が異常に遅い（28x） | EFA が TCP fallback | `NCCL_SOCKET_IFNAME=^lo,docker,veth`（除外形） |
| TTFT が数十秒 spike | cold-JIT（sm_103） | JIT キャッシュ永続化 + warmup 捨て打ち |
| 全 HTTP が 500 | fastapi のビルドドリフト | `fastapi==0.116.0` + instrumentator 7.1.0 にピン |
| ビルドが tar chown で失敗 | rootless BuildKit | 非 rootless + privileged |
| イメージが pull できない | cross-account ECR | repo policy にノードロールを追加 |
| Pod から S3 が AccessDenied | ノードロールに S3 権限なし | kubectl cp 経由で吸い出す |
| kustomize が resources エラー | 絶対パス指定 | overlay を repo 内に置き相対パス |

---

## まとめ

最新世代 GPU（B300 / sm_103）で Disaggregated Inference を動かすには、**イメージのビルド（sm_103 対応とビルドドリフト回避）**、**EFA / NCCL / JIT の正しい設定**、**cross-account や taint といったクラスタ固有の作法**という、複数の層のハマりどころを越える必要がありました。

逆に言えば、これらを一度押さえてしまえば、vLLM native でも llm-d でも同じ足回り（イメージ・JIT キャッシュ・EFA・taint）を使い回せます。理論編で示した「long-context での数倍差」のような結果も、この土台の上で初めて測定できます。

実装一式・ベンチマークスクリプト・生データは [github.com/littlemex/distributed-inference](https://github.com/littlemex/distributed-inference) で公開しています。
