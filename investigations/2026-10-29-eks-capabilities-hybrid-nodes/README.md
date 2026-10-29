# EKS Capabilities の Argo CD から、オンプレミスの Hybrid Nodes と EKS 以外の Kubernetes に配る

EKS Capabilities のマネージド Argo CD を 1 か所に置き、オンプレミスのサーバーと、EKS ではない Kubernetes クラスタ (AKS、GKE、自前構築など) の両方に Helm chart を配れるかを、実機で確かめた。Zenn の記事「EKS Hybrid Nodes と EKS Capabilities でオンプレミスの Kubernetes にデプロイする」の数値とログは、すべてこのディレクトリのコードで再現できる。

## 結論

| # | 確かめたこと | 結果 |
|---|---|---|
| T1 | マネージド Argo CD が、Hybrid Nodes として参加したオンプレミス役のサーバーに Helm chart を配る | 配れる。Pod はそのノードの上で、オンプレミス側の Pod CIDR の IP で動く。AWS 側のノードの Pod から送ったリクエストに応答する |
| T2 | マネージド Argo CD に、EKS ではないクラスタを API サーバーの URL とトークンで登録する | 登録できない。Application の condition に `server should be specified as a cluster ARN` が出て、k3s に namespace は作られない |
| T3 | マネージド Argo CD が 2 段目の Argo CD を EKS に入れ、2 段目が EKS ではないクラスタ (k3s) に配る | 配れる。マネージド側の 2 つの Application (`tier2-argocd` と `tier2-apps`) と、2 段目の Application が Synced と Healthy になる |
| T4 | マネージド Argo CD の上の 2 つの Application (`podinfo-onprem` と `tier2-apps`) の値だけを変える | 両方のデプロイ先で、Deployment が全レプリカを更新し、各 Pod が自分の IP で新しいメッセージを返す |
| T5 | EKS ではないクラスタで手で消した Deployment が、2 段目の Argo CD で作り直される | 作り直される |
| T6 | クラスタの API の入口を private だけにして、Hybrid ノードの kubelet の接続先を見る | hub VPC の private アドレスに接続する |

マネージド Argo CD の配り先は EKS クラスタ ARN だけである。オンプレミスは Hybrid Nodes で EKS クラスタの一部にすれば直接配れる。EKS ではないクラスタには、マネージド Argo CD が入れた 2 段目の Argo CD を経由して配る。

## 構成

3 つの VPC を Transit Gateway でつなぎ、3 つの環境に見立てる。

| VPC | CIDR | 役 | 中身 |
|---|---|---|---|
| hub | 10.0.0.0/16 | AWS | EKS クラスタ (API の入口は private だけ)、managed node group 1 台、マネージド Argo CD |
| onprem | 10.80.0.0/16 | オンプレミス | Hybrid Node として参加する EC2 1 台。Pod CIDR は 10.81.0.0/16 |
| other | 10.90.0.0/16 | EKS ではない Kubernetes | k3s を入れた EC2 1 台 |

Transit Gateway は、オンプレミスと AWS をつなぐ VPN や Direct Connect の代わりである。オンプレミス役の EC2 には instance profile を付けず、AWS の認証は Systems Manager のハイブリッドアクティベーションだけで行う。物理サーバーを参加させるときと同じ条件にするためである。

EKS Hybrid Nodes を EC2 や他社クラウドで動かすことは [AWS のサポート対象外](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-overview.html#hybrid-nodes-general)である。この構成は検証のための模擬であり、本番の構成ではない。

## ディレクトリ

```
2026-10-29-eks-capabilities-hybrid-nodes/
├── terraform/
│   ├── main.tf                  3 つの VPC、Transit Gateway、EKS、Hybrid Node、k3s、マネージド Argo CD
│   └── userdata/                Hybrid Node と k3s の起動時の処理
├── k8s/
│   ├── cilium-values.yaml       Hybrid ノードだけで動く Cilium の設定
│   ├── t1-podinfo-onprem.yaml   T1 の Application
│   ├── t2-podinfo-direct.yaml   T2 の Application
│   ├── t3-tier2-argocd.yaml     T3 の 2 段目の Argo CD と、その配り先の Application
│   └── k3s-deployer-sa.yaml     k3s 側で Argo CD が使う ServiceAccount
├── scripts/
│   ├── run-all.sh               構築、検証、削除を順に流す。失敗しても削除は必ず流す
│   ├── env.sh                   3 つの値からほかの値を求める (run-all.sh と cleanup.sh が読む)
│   ├── verify.sh                T1〜T6 を流し、項目ごとに [PASS] か [FAIL] を出す
│   ├── port-forward.sh          private な API の入口に SSM のポート転送で入る
│   ├── register-k3s.sh          k3s を Argo CD のクラスタとして登録する
│   ├── ssm-run.sh               SSM Run Command でコマンドを実行する
│   └── cleanup.sh               すべて削除する
└── results/                     verify.sh の出力 (verify.log)
```

ノードへの操作はすべて SSM Run Command で行い、SSH は使わない。

## 再現の手順

必要なもの: Terraform 1.9 以降、AWS CLI v2 と Session Manager プラグイン、kubectl、Helm 3.8 以降、Python 3、nc。AWS CLI は、VPC、EKS、EC2、IAM、Systems Manager、S3 を作って消せる権限で認証しておく。認証の有効期限は、構築から削除まで (1 時間ほど) 残っている必要がある。AWS アカウントには IAM Identity Center のインスタンスとユーザーが要る。`env.sh` は、道具とその版、AWS CLI の認証を最初に確かめ、足りなければ何も作らずに止まる。マネージド Argo CD はログインに Identity Center を使うからである。Identity Center は別のリージョンにあってよい。

最初に環境ごとの値を 3 つ設定する。`AWS_REGION` は環境を作るリージョン、`IDC_REGION` は IAM Identity Center のあるリージョン、`TF_STATE_BUCKET` は Terraform の state を置く自分の S3 バケットである。

```bash
export AWS_REGION=us-east-2
export IDC_REGION=us-east-1
export TF_STATE_BUCKET=your-terraform-state-bucket
```

ほかの値は `scripts/env.sh` が求める。state のバケットのリージョンを引き、Identity Center のユーザーが 1 人ならそのユーザーをマネージド Argo CD の管理者にする。ユーザーが複数いると名前の一覧を出して止まる。そのときは何も作られていないので、同じシェルで `export TF_VAR_idc_admin_user_name=` に 1 人の名前を入れ、`./scripts/run-all.sh` だけを流し直す。

続けて、構築、検証、削除を流す。構築に 20 分ほど、検証に 15 分ほどかかる。

```bash
git clone https://github.com/littlemex/distributed-ai.git && cd distributed-ai/investigations/2026-10-29-eks-capabilities-hybrid-nodes && ./scripts/run-all.sh
```

`run-all.sh` は、値が足りないか引けないとき、Identity Center のユーザーが複数いるとき、state を読めないとき、同じ state のキー (`eks/ekscap-hub/terraform.tfstate`) に何かが残っているときは、何も作らずに止まる。そうでなければ `terraform apply`、`verify.sh`、`cleanup.sh` の順に流す。構築や検証が途中で失敗しても `cleanup.sh` は必ず流れる。`verify.sh` は T1〜T6 の 1 行ずつに `[PASS]` か `[FAIL]` を出し、同じ内容を `results/verify.log` に書く。最後の行が `build=0 verify=0 cleanup=0` で終了コードが 0 なら、構築、全項目、削除のすべてが通った。

`verify.sh` は手元の 8443 番ポートで EKS の API エンドポイントにつなぐ。使われていれば止まるので、`export LOCAL_PORT=` に空いているポートを入れて流し直す。途中で Ctrl-C を押すと、`run-all.sh` はそこまでに作ったものを `cleanup.sh` で消してから終わる。

流している間は、EKS クラスタ、マネージド Argo CD、EC2 3 台 (managed node group、Hybrid Node、k3s)、Hybrid Node の vCPU あたりの料金、NAT Gateway、Transit Gateway と 3 つの接続が課金される。`cleanup` が 0 以外で終わったら、残ったものがあるので、同じシェルで次を流す。最後の行が `deregister=0 destroy=0 resources left in state=0` になれば消えている。

```bash
./scripts/cleanup.sh
```

新しいシェルから消すときは、最初の 3 つの `export` (と、指定したなら `TF_VAR_idc_admin_user_name`) を流してから、clone したディレクトリで `./scripts/cleanup.sh` を流す。

## 各項目が何を示すか

**T1** は、マネージド Argo CD がオンプレミスのサーバーに直接配れることを示す。Argo CD が話す相手は AWS 側にある EKS の API サーバーだけで、Pod をどのノードに置くかは Kubernetes のスケジューラが決める。そのため、Application の `nodeSelector` に `eks.amazonaws.com/compute-type: hybrid` を書くだけで、オンプレミスのノードに置かれる。`verify.sh` は全 Pod がそのノードの上で 10.81.0.0/16 の IP を持つこと、AWS 側のノードの Pod から Service 経由で応答が返ることを確かめる。

**T2** は、EKS ではないクラスタをマネージド Argo CD に直接登録できないことを示す。エラーは RESTConfig (接続の設定) を組み立てる段階のもので、`server` が ARN でないことを理由にしている。[公式文書](https://docs.aws.amazon.com/eks/latest/userguide/argocd-comparison.html)にも "The capability supports only Amazon EKS clusters as deployment targets using EKS cluster ARNs (not Kubernetes API server URLs)." とある。`verify.sh` は condition の全文を `[INFO]` の行に残す。

**T3** は、EKS ではないクラスタに配る道を示す。マネージド Argo CD は、hub クラスタに通常の Argo CD (Helm chart `argo-cd`) を入れ、その Argo CD が持つ Application (Helm chart `argocd-apps`) も配る。2 段目の Argo CD は通常の Argo CD なので、API サーバーの URL とトークンで k3s を登録できる。CRD はマネージド Argo CD が入れたものを共有するので、2 段目では `crds.install: false` にし、Argo CD の版をマネージド側 (3.4 系) にそろえる。 2 段目の Argo CD は、`cluster.inClusterEnabled: "false"` で自分が動く hub クラスタをデプロイ先にできなくし、k3s の Application は `default` ではなく、デプロイ先を k3s の `podinfo-other` に、取得元を podinfo の chart リポジトリに限った AppProject `edge` に入れる。chart の既定のままのものもある。2 段目の application-controller は hub クラスタ全体を読み書きできる ClusterRole を持ち、2 段目の UI と API には Identity Center ではなくローカルの admin でログインする。

**T4** は、配る内容を変えるときに触るのがマネージド Argo CD の Application だけで済むことを示す。2 段目の Application も、マネージド Argo CD が `argocd-apps` の値として配るからである。ただし、k3s を登録する cluster secret (トークン) は `register-k3s.sh` が 2 段目の namespace に直接置き、マネージド Argo CD は配らない。完了は、Deployment の ready、updated、replicas がすべて新しいレプリカ数になり、Running の Pod のそれぞれが自分の IP で新しいメッセージを返すこととする。2 つのデプロイ先は同じループで 5 秒ごとに確かめるので、秒数は最初の patch から、確認の間隔と SSM Run Command の往復を含む上限である。

**T5** は、2 段目の Argo CD が配り先のずれを検知して戻すことを示す。削除した時刻と作り直された Deployment の `creationTimestamp` は、どちらも k3s のマシンの時計で取る。

**T6** は、オンプレミスとの経路が private であることを示す。Hybrid Nodes のクラスタは [API の入口に public と private の併用を使えない](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-cluster-create.html)。併用すると、VPC の外のノードからは名前が public の IP に解決されるからである。この構成では private だけにしたので、kubelet は Transit Gateway を通って hub VPC の ENI に接続する。マネージド Argo CD は [private だけのクラスタにも配れる](https://docs.aws.amazon.com/eks/latest/userguide/argocd-register-clusters.html#_private_clusters)。

## 限界

- オンプレミスと他社クラウドは EC2 で模擬した。実機のオンプレミスでの違いは、Hybrid Node が VPN か Direct Connect を通ること、OS が [AWS の対応表](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-os.html)に載っている必要があることである。
- 他社クラウドの VM やベアメタルを Hybrid Nodes にすることは、AWS のサポート対象外である。nodeadm のソースにクラウドを判定して拒否するコードは無いが、それはサポートされることを意味しない。
- Argo CD の権限は、短く確かめるために `AmazonEKSClusterAdminPolicy` と `cluster-admin` にした。実運用では namespace と resource を[最小権限](https://docs.aws.amazon.com/eks/latest/userguide/argocd-register-clusters.html#_production_setup_with_least_privilege)に絞る。
- 2 段目の Argo CD の保守 (版の更新、可用性) は利用者の責任になる。マネージドなのは 1 段目だけである。
- T4 の秒数は確認の間隔と SSM Run Command の往復を含む上限で、Argo CD が反映するまでの時間そのものではない。
- EKS ではないクラスタへの配布は k3s で確かめた。AKS や GKE では試していない。
