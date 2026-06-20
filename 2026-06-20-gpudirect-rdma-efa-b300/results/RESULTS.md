# GPU Direct RDMA 実機実験 結果

**日付**: 2026-06-20
**クラスタ**: ml-clusters-shared-us-west-2 (EKS 1.35)
**namespace**: akazawt-gpudirect-rdma
**ノード**: p6-b300.48xlarge ×2（NVIDIA B300 SXM6, compute_cap 10.3 / sm_103, 8 GPU/node, EFA 16/node）
**イメージ**: public.ecr.aws/hpc-cloud/nccl-tests:latest（EFA installer + libfabric 2.1.0amzn5 + nccl-tests + NCCL 2.27.7 同梱）
**配置**: rdma-server → ip-10-3-67-21 (10.3.67.21) / rdma-client → ip-10-3-70-29 (10.3.70.29)（podAntiAffinity で別ノード）

## ステップ0: EFA provider 確認（fi_info -p efa）

p4d では `No data available` だったが、B300（EFA ENI アタッチ済み）では 16 provider が見えた:

```
provider: efa
    fabric: efa-direct
    domain: rdmap86s0-rdm
    version: 201.0
    type: FI_EP_RDM
    protocol: FI_PROTO_EFA
（... 計16 NIC ...）
libfabric: 2.1.0amzn5.0
```

`/dev/gdrdrv` も存在（GPUDirect 即利用可）。`/sys/class/infiniband/` に rdmap*/ibp* デバイス。

## デモ1: fi_pingpong（2ノード間 EFA RDMA の RTT）

`fi_pingpong -p efa -e rdm -I 1000`（server 10.3.67.21 ← client 10.3.70.29）:

| bytes | usec/xfer（往復RTT） | MB/sec |
|---|---|---|
| 64 | 11.78 | 5.43 |
| 256 | 10.34 | 24.75 |
| 1K | 10.53 | 97.21 |
| 4K | 11.44 | 357.90 |

→ **2 物理ノード間で往復約 10〜12 µs**。ブログの「RDMA は一桁〜数µs / TCP は数十〜百数十µs」と整合。

（参考: 同一ノード loopback では 64B=81µs と出たが、これは初回 connection setup 込み。ノード間の定常値が上表。）

## デモ2: nccl-tests all_reduce（GPUDirect RDMA over EFA）

### 単一ノード 8GPU（NVLink/NVSwitch 経由・参考）
NCCL 2.27.7+cuda12.8。busbw: 8MB=185 GB/s … 1GB=**734 GB/s**（Avg 489 GB/s）。

### 2ノード 16GPU（ノード間 EFA / GPUDirect RDMA）— 本命
`mpirun -np 16 -N 8 -H ...:8,...:8`（port 2222 SSH）。NCCL ログで GPUDirect RDMA over EFA を確認:

```
NCCL INFO NET/OFI Initializing aws-ofi-nccl 1.16.3
NCCL INFO NET/OFI Using Libfabric version 2.1
NCCL INFO NET/OFI Selected provider is efa, fabric is efa-direct (found 16 nics)
NCCL INFO NET/OFI Using transport protocol RDMA (platform set)
```

→ ブログのデモ2で「これが出れば EFA 経由の決定的証拠」とした **`Selected provider is efa`** が実機で確認できた。

busbw（2ノード16GPU、ノード間 EFA）:

| size | busbw |
|---|---|
| 8 MB | 100 GB/s |
| 16 MB | 166 GB/s |
| 128 MB | 425 GB/s |
| 256 MB | 492 GB/s |
| 1 GB | 514 GB/s |
| 2 GB | **708 GB/s** |

（Avg 363.9 GB/s。小サイズはレイテンシ律速、大サイズで EFA 帯域に漸近。）

## ブログへの反映ポイント
- 前編 ステップ0: 「p4d は空 / B300 は 16 provider」の対比が実機で確定。`fabric: efa-direct`・`protocol: FI_PROTO_EFA` の実値
- 前編 デモ1: 2ノード RTT 実測（10〜12µs）
- 前編 デモ2: `Selected provider is efa` の実ログ + busbw 実測（2GB で 708 GB/s）
- 環境セットアップ（namespace 作成〜pod〜SSH〜mpirun）を「k8s で動かす」手順としてブログに追加
- B300/sm_103 という最新世代での実測（前編は p4d=A100 の話だった）

## 手順メモ（再現用）
1. `kubectl create namespace akazawt-gpudirect-rdma`
2. `manifests/10-two-nodes.yaml` 適用（5 taint + nodeSelector + hostNetwork + privileged + gdrdrv + EFA + NCCL除外env）
3. SSH 鍵を両 pod で共有、sshd を port 2222 で起動
4. server pod から `mpirun -np 16 -N 8 -H srv:8,cli:8 --mca plm_rsh_args '-p 2222' ... all_reduce_perf`
