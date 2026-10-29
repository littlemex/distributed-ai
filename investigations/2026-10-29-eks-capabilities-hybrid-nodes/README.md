# EKS Capabilities の Argo CD から、オンプレミスの Hybrid Nodes と EKS 以外の Kubernetes に配る

EKS Capabilities のマネージド Argo CD を 1 か所に置き、オンプレミスのサーバーと、EKS ではない Kubernetes クラスタ (AKS、GKE、自前構築など) の両方に Helm chart を配れるかを、実機で確かめた。Zenn の記事「EKS Hybrid Nodes と EKS Capabilities でオンプレミスの Kubernetes にデプロイする」の数値とログは、すべてこのディレクトリのコードで再現できる。

## 結論

| # | 確かめたこと | 結果 |
|---|---|---|
| T1 | マネージド Argo CD が、Hybrid Nodes として参加したオンプレミスのサーバーに Helm chart を配る | 配れる。Pod はオンプレミス側のノードとオンプレミス側の Pod CIDR で動き、AWS 側の Pod から応答が返る |
| T2 | マネージド Argo CD に、EKS ではないクラスタを API サーバーの URL とトークンで登録する | 登録できない。`server should be specified as a cluster ARN` で拒否され、接続も試みない |
| T3 | マネージド Argo CD が 2 段目の Argo CD を EKS に入れ、2 段目が EKS ではないクラスタに配る | 配れる |
| T4 | マネージド Argo CD の Application を 1 か所変えると、両方の配り先に反映される | 反映される |
| T5 | EKS ではないクラスタで手で消したワークロードが、2 段目の Argo CD で戻る | 戻る |
| T6 | クラスタの API の入口を private だけにしても、Hybrid ノードが private な経路で参加し、マネージド Argo CD が配れる | 参加でき、配れる。kubelet は hub VPC の private アドレスに接続する |

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
│   ├── verify.sh                T1〜T6 を流し、項目ごとに [PASS] か [FAIL] を出す
│   ├── port-forward.sh          private な API の入口に SSM のポート転送で入る
│   ├── register-k3s.sh          k3s を Argo CD のクラスタとして登録する
│   ├── ssm-run.sh               SSM Run Command でコマンドを実行する
│   └── cleanup.sh               すべて削除する
└── results/                     verify.sh の出力 (verify.log)
```

ノードへの操作はすべて SSM Run Command で行い、SSH は使わない。

## 再現の手順

必要なもの: Terraform 1.9 以降、AWS CLI v2 と Session Manager プラグイン、kubectl、Helm 3.8 以降、Python 3、nc。AWS アカウントには IAM Identity Center のインスタンスとユーザーが要る。マネージド Argo CD はログインに Identity Center を使うからである。Identity Center は別のリージョンにあってよい。

最初に環境ごとの値を設定する。`TF_STATE_BUCKET` は Terraform の state を置く S3 バケットである。

```bash
export AWS_REGION=us-east-2
export IDC_REGION=us-east-1
export IDC_ADMIN_USER_NAME=$(aws identitystore list-users --no-paginate --region "$IDC_REGION" --identity-store-id "$(aws sso-admin list-instances --no-paginate --region "$IDC_REGION" --query 'Instances[0].IdentityStoreId' --output text)" --query 'Users[0].UserName' --output text)
export TF_STATE_BUCKET=your-terraform-state-bucket
export TF_STATE_REGION=$(aws s3api get-bucket-location --bucket "$TF_STATE_BUCKET" --query LocationConstraint --output text | sed 's/None/us-east-1/')
export TF_VAR_region=$AWS_REGION TF_VAR_idc_region=$IDC_REGION TF_VAR_idc_admin_user_name=$IDC_ADMIN_USER_NAME
```

`IDC_ADMIN_USER_NAME` は Identity Center の最初のユーザーを取る。別のユーザーを Argo CD の管理者にするなら、そのユーザー名を入れる。

続けて、構築、検証、削除を流す。構築に 20 分ほど、検証に 15 分ほどかかる。

```bash
git clone https://github.com/littlemex/distributed-ai.git
cd distributed-ai/investigations/2026-10-29-eks-capabilities-hybrid-nodes
terraform -chdir=terraform init -input=false -backend-config="bucket=$TF_STATE_BUCKET" -backend-config="key=eks/ekscap-hub/terraform.tfstate" -backend-config="region=$TF_STATE_REGION"
terraform -chdir=terraform apply -auto-approve -input=false
./scripts/verify.sh; VERIFY_STATUS=$?
./scripts/cleanup.sh
echo "verify exit status: $VERIFY_STATUS"
```

`verify.sh` は 6 行の `[PASS]` を出し、`results/verify.log` にも同じ内容を書く。最後の行が `verify exit status: 0` なら全項目が通った。1 つでも `[FAIL]` があれば 1 になる。検証の成否にかかわらず、`cleanup.sh` はすべてを削除する。

## 各項目が何を示すか

**T1** は、マネージド Argo CD がオンプレミスのサーバーに直接配れることを示す。Argo CD が話す相手は AWS 側にある EKS の API サーバーだけで、Pod をどのノードに置くかは Kubernetes のスケジューラが決める。そのため、Application の `nodeSelector` に `eks.amazonaws.com/compute-type: hybrid` を書くだけで、オンプレミスのノードに置かれる。`verify.sh` は全 Pod がそのノードの上で 10.81.0.0/16 の IP を持つこと、AWS 側のノードの Pod から Service 経由で応答が返ることを確かめる。

**T2** は、EKS ではないクラスタをマネージド Argo CD に直接登録できないことを示す。拒否は cluster secret の `server` を読む段階で起き、相手への接続より前である。したがって、ネットワークがつながっていても結果は変わらない。[公式文書](https://docs.aws.amazon.com/eks/latest/userguide/argocd-comparison.html)にも "The capability supports only Amazon EKS clusters as deployment targets using EKS cluster ARNs (not Kubernetes API server URLs)." とある。

**T3** は、EKS ではないクラスタに配る道を示す。マネージド Argo CD は、hub クラスタに通常の Argo CD (Helm chart `argo-cd`) を入れ、その Argo CD が持つ Application (Helm chart `argocd-apps`) も配る。2 段目の Argo CD は通常の Argo CD なので、API サーバーの URL とトークンで k3s を登録できる。CRD はマネージド Argo CD が入れたものを共有するので、2 段目では `crds.install: false` にし、Argo CD の版をマネージド側 (3.4 系) にそろえる。

**T4** は、配る内容の正本がマネージド Argo CD の Application だけで済むことを示す。2 段目の Application も、マネージド Argo CD が `argocd-apps` の値として配るからである。

**T5** は、2 段目の Argo CD が配り先のずれを検知して戻すことを示す。

**T6** は、オンプレミスとの経路が private であることを示す。Hybrid Nodes のクラスタは [API の入口に public と private の併用を使えない](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-cluster-create.html)。併用すると、VPC の外のノードからは名前が public の IP に解決されるからである。この構成では private だけにしたので、kubelet は Transit Gateway を通って hub VPC の ENI に接続する。マネージド Argo CD は [private だけのクラスタにも配れる](https://docs.aws.amazon.com/eks/latest/userguide/argocd-register-clusters.html#_private_clusters)。

## 限界

- オンプレミスと他社クラウドは EC2 で模擬した。実機のオンプレミスでの違いは、Hybrid Node が VPN か Direct Connect を通ること、OS が [AWS の対応表](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-os.html)に載っている必要があることである。
- 他社クラウドの VM やベアメタルを Hybrid Nodes にすることは、AWS のサポート対象外である。nodeadm のソースにクラウドを判定して拒否するコードは無いが、それはサポートされることを意味しない。
- Argo CD の権限は、短く確かめるために `AmazonEKSClusterAdminPolicy` と `cluster-admin` にした。実運用では namespace と resource を[最小権限](https://docs.aws.amazon.com/eks/latest/userguide/argocd-register-clusters.html#_production_setup_with_least_privilege)に絞る。
- 2 段目の Argo CD の保守 (版の更新、可用性) は利用者の責任になる。マネージドなのは 1 段目だけである。
- T4 と T5 の秒数は、SSM Run Command で状態を読む往復を含む上限であり、Argo CD の反映時間そのものではない。
