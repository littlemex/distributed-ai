# Infra-Layer Smoke Tests

`terraform apply` 後にクラスタの各コンポーネントが正常に動作しているかを確認するスモークテストです。実行は任意ですが、初回構築後やモジュール変更後に回すと安心です。

## 前提

- `kubectl` が対象クラスタに向いている (クラスタ名は `terraform output cluster_name` で確認できます)
- `aws` CLI が認証済み
- `envsubst` が使える (macOS: `brew install gettext`)

## 実行方法

```bash
cd infra/eks/tests

# 基盤テストのみ (GPU ノードを起動しない、約1分)
./run-tests.sh --profile <your-profile>

# GPU テストも含む (Karpenter が GPU ノードを起動、5-10分)
./run-tests.sh --with-gpu --profile <your-profile>
```

## オプション

| フラグ | 既定値 | 説明 |
|---|---|---|
| `--with-gpu` | false | GPU テスト (ノード起動 + nvidia-smi + CUDA + FSx) も実行 |
| `--keep-ns` | false | テスト後に namespace/リソースを残す (失敗調査用) |
| `--namespace NAME` | `distai-test` | テスト用 namespace 名 |
| `--cluster-name NAME` | `terraform output cluster_name` | kubectl context のクラスタ名検証に使用。省略時は Terraform の output から解決 |
| `--region REGION` | `terraform output region` | AWS CLI のリージョン。省略時は Terraform の output から解決 (取れなければ `AWS_DEFAULT_REGION`) |
| `--profile PROFILE` | (ambient) | AWS CLI の名前付き profile |
| `--gpu-count N` | `1` | nvidia-smi で確認する GPU 枚数 |
| `--timeout-gpu SEC` | `600` | GPU テスト個別タイムアウト (秒) |

## テスト一覧

### 基盤テスト (GPU 不要)

| テスト | 確認内容 |
|---|---|
| control-plane | EKS クラスタが ACTIVE、Kubernetes API に到達可能 |
| system-nodes | System ノードグループのノードが 2 台 Ready |
| karpenter | Karpenter Pod 2/2 Running、全 NodePool と EC2NodeClass が Ready |
| trainer | Kubeflow Trainer v2 (manager + JobSet) が Running |
| csi-drivers | EBS/EFS/FSx Lustre/OpenZFS の DaemonSet + Controller が Ready |
| storage-mount | テスト専用 PV 経由で FSx Lustre と OpenZFS に read/write |

### GPU テスト (`--with-gpu`)

| テスト | 確認内容 |
|---|---|
| gpu-node-launch+nvidia-smi | Karpenter が gpu-dev NodePool でノードを起動し nvidia-smi が成功 |
| nvidia-smi-check | nvidia-smi 出力に GPU が `--gpu-count` 枚以上見える |
| cuda-vector-add | CUDA サンプル (vectorAdd) が "Test PASSED" で完了 |
| gpu-fsx-mount | GPU ノード上の Pod から FSx/OpenZFS に read/write |

## 出力例

```
[INFO] === EKS Infra Smoke Tests ===
[INFO] cluster: <cluster_name>, namespace: distai-test, with-gpu: false, gpu-count: 1
[INFO] --- Base Tests ---
[OK]   control-plane (5s)
[OK]   system-nodes (4s)
[OK]   karpenter (8s)
[OK]   trainer (2s)
[OK]   csi-drivers (33s)
[OK]   storage-mount (47s)

==============================
 Test Summary
==============================
STATUS   TEST                                DETAIL
--------------------------------------------------------------
PASS     control-plane                       5s
PASS     system-nodes                        4s
PASS     karpenter                           8s
PASS     trainer                             2s
PASS     csi-drivers                         33s
PASS     storage-mount                       47s
--------------------------------------------------------------
PASS: 6  FAIL: 0  SKIP: 0  TOTAL: 6
```

## 設計上の注意

- テスト用 PV は本番 PV と同じファイルシステムを `subPath: smoke-test` で隔離してマウントするため、本番データには書き込まない
- テスト用 PV の `volumeHandle` は本番と異なる一意な値を付けており、同一ノード上でのマウント競合を回避
- GPU テストで ICE (InsufficientInstanceCapacity) が発生した場合はノード起動失敗として後続 GPU テストが SKIP になる (AWS 側のキャパシティ問題であり、インフラの不具合ではない)
- GPU ノードの削除はテストスクリプトでは行わず、Karpenter の consolidation (既定 5 分) に委ねる
