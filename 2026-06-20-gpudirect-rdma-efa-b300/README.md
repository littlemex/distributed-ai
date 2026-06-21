# GPUDirect RDMA over EFA on Amazon EKS + NVIDIA B300

NVIDIA B300 (Blackwell, sm_103) を使った Amazon EKS 上で、**GPUDirect RDMA over EFA**
が実際に効いていることを、`fi_pingpong`(往復レイテンシ)と `nccl-tests`(集団通信帯域)
で計測・実証した記録。clone してそのまま再現できる manifest と recipe を同梱。


## ディレクトリ

```
2026-06-20-gpudirect-rdma-efa-b300/
├── manifests/   # k8s manifest (2ノード server/client, 調査用 probe)
├── recipe/      # 再現スクリプト (fi_pingpong / nccl-tests)
└── results/     # 実測の生記録
```

## 計測サマリ (B300 ×2 ノード, EFA 16/node)

### fi_pingpong — 2 ノード間 EFA RDMA の往復レイテンシ

| メッセージ | usec/xfer (往復RTT) | MB/sec |
|---|---|---|
| 64 B | 11.78 | 5.43 |
| 256 B | 10.34 | 24.75 |
| 1 KB | 10.53 | 97.21 |
| 4 KB | 11.44 | 357.90 |

→ 2 物理ノード間で **往復約 10〜12 µs**。同一データセンタの TCP(数十〜百数十µs)と一桁違う。

### nccl-tests all_reduce — 16 GPU, ノード間 EFA(GPUDirect RDMA)

GPUDirect RDMA over EFA が効いている決定的ログ:

```
NCCL INFO NET/OFI Selected provider is efa, fabric is efa-direct (found 16 nics)
NCCL INFO NET/OFI Using transport protocol RDMA (platform set)
```

| size | busbw |
|---|---|
| 8 MB | 100 GB/s |
| 128 MB | 425 GB/s |
| 1 GB | 514 GB/s |
| 2 GB | 708 GB/s |

(小サイズはレイテンシ律速、大サイズで EFA 帯域に漸近。参考: 単一ノード 8GPU NVLink は 1GB で 734 GB/s。)

詳細な生データは [results/RESULTS.md](./results/RESULTS.md)。

---

## 再現手順 (clone してから)

クラスタは `ml-clusters-shared-us-west-2` (EKS 1.35, p6-b300.48xlarge, EFA 16/node,
`/dev/gdrdrv` フリート提供済み)。詳しいクラスタの作法は社内 CLUSTER-GUIDE を参照。

### 0. 前提とアクセス

```bash
# このリポジトリを clone
git clone git@github.com:littlemex/distributed-inference.git
cd distributed-inference/2026-06-20-gpudirect-rdma-efa-b300

# kubeconfig (Isengard 認証 → AssumeRole 済みの前提)
aws eks update-kubeconfig --name ml-clusters-shared-us-west-2 --region us-west-2 --profile ml-shared-uw2
kubectl get nodes -l nvidia.com/gpu.product=NVIDIA-B300-SXM6-AC   # B300 が見えるか

# GPU 空き確認 (2 ノード以上空いていること)
kubectl get pods -A -o json | jq -r '.items[]|select(.status.phase=="Running")|select([.spec.containers[].resources.requests."nvidia.com/gpu"//"0"]|map(tonumber)|add>0)|"\(.metadata.namespace)/\(.metadata.name)"'
```

### 1. namespace 作成

```bash
kubectl create namespace myuser-gpudirect-rdma
```

### 2. 2 ノードに pod を立てる

```bash
kubectl apply -f manifests/10-two-nodes.yaml
# 両方 Running になるまで待つ (初回は image pull 6.5GB で約2分)
kubectl -n myuser-gpudirect-rdma get pods -l app=rdma-bench -o wide -w
```

`rdma-server` と `rdma-client` が**別ノード**で `Running` になれば OK
(podAntiAffinity でノード分散される)。

### 3. デモ1: fi_pingpong (RTT 実測)

```bash
NAMESPACE=myuser-gpudirect-rdma ./recipe/run-fi-pingpong.sh
```

→ `fi_info -p efa` が provider を返し、`usec/xfer` 列に往復 RTT が出る。

### 4. デモ2: nccl-tests all_reduce (GPUDirect RDMA over EFA)

```bash
NAMESPACE=myuser-gpudirect-rdma ./recipe/run-nccl-allreduce.sh
```

→ `Selected provider is efa` のログ + `busbw` テーブルが出れば成功。

### 5. 後片付け (借用クラスタなので必須)

```bash
kubectl -n myuser-gpudirect-rdma delete pod rdma-server rdma-client rdma-probe --ignore-not-found
# GPU 解放確認 (空ならゼロ行)
kubectl get pods -A -o json | jq -r '.items[]|select(.status.phase=="Running")|select([.spec.containers[].resources.requests."nvidia.com/gpu"//"0"]|map(tonumber)|add>0)|.metadata.name'
# namespace は再利用のため残してよい
```

---

## ハマりどころ

| 症状 | 原因 | 対処 |
|---|---|---|
| pod が Pending | taint への toleration 不足 | manifest の 5 つの toleration を確認 |
| `fi_info -p efa` が空 | そのノードに EFA ENI が無い | B300 なら通常付いている。別ノードへ |
| 通信が異常に遅い | EFA が TCP fallback | `NCCL_SOCKET_IFNAME=^lo,docker,veth`(除外 `^` が必須) |
| mpirun が SSH で失敗 | sshd 未起動 / 鍵未共有 | recipe が port 2222 で自動セットアップ |
| image pull が遅い | nccl-tests イメージ 6.5GB | 初回のみ。`-w` で待つ |

## 使用イメージ

`public.ecr.aws/hpc-cloud/nccl-tests:latest`(AWS 公式)。EFA installer
(libfabric 2.1.0amzn5, `fi_info`/`fi_pingpong`) + nccl-tests + NCCL 2.27.7 を同梱。
公開イメージなので cross-account ECR 設定は不要。
