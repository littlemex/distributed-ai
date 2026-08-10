# ComfyUI + MiniMax-H3 プロジェクトルール

**最終更新**: 2026-08-10

このプロジェクトが守る設計不変条件。逸脱するコードはレビューで差し戻す。

## 1. base module (`infra/eks`) は child 参照。改善は責務境界に沿って upstream 貢献する

- `../infra/eks` は **child module として参照するだけ**（`module "cluster" { source = "../../infra/eks" }`）。
  複製・シンボリックリンクは禁止。ComfyUI 固有の資産（ECR repo、Deployment、workflow）は
  この root 側／`charts/comfyui` に置く。
- base module の `charts/experiments` は触らない。ComfyUI ワークロードは独立 chart `charts/comfyui`。
- **base の「責務的に入れるべき汎用機能」の欠落は、workaround で消費者側に溜めずに upstream 貢献する。**
  image-builder は「汎用ビルダー機構」を名乗りながら push 権限が `ddp-sample` 1 repo に溶接され、
  builder identity も未 output だった。これは base 自身の宣言との内部矛盾なので、後方互換
  (default=[] で byte-identical plan、検証済み) を保った最小変更で base に貢献した:
  `image_builder_additional_ecr_repository_arns` 変数と builder identity の output 4 つ。
  消費者側（この root）は **ECR repo を1つ作り、その ARN を module に渡すだけ**。IAM は一切
  管理しない（repo=「何をビルドするか」は消費者、権限機構=base の責務、という一行境界）。

## 2. State を分離する

- 本 root は **独自の Terraform state** を `terraform/` に持つ。既存の us-east-2 /
  distai-eks-smoke state を参照・変更してはならない。
- 長期運用するなら `versions.tf` の S3 backend（`use_lockfile=true`、env ごとに key 分離）を
  有効化する。local state のまま放置しない。

## 3. ComfyUI を公開しない

- ComfyUI は無認証で、Web UI から任意 Python 実行（custom node）が可能 = 実質 RCE。
  よって **`kubectl port-forward` 経由のみ**。Service は ClusterIP 固定。
- base module の `enable_demo_app` / `enable_cloudfront` は **false 固定**。将来どうしても
  公開が要るなら ALB authenticate-oidc + Cognito を足す（README/GETTING_STARTED 参照）。

## 4. ステートフル単一 Pod を守る

- ComfyUI は単一 GPU・インメモリキュー。よって:
  - Deployment `strategy: Recreate`（RollingUpdate は GPU 待ちでデッドロック）。
  - Pod に `karpenter.sh/do-not-disrupt: "true"`、NodePool は `disruption=protect`。
  - `capacity_types` の既定は `["on-demand"]`（Spot 回収で生成が全損するため）。
- 24GB カード（g6/g5）は 33B 動画モデルに信頼性が低いためサービングパスから除外。実験するなら
  `extra_accelerator_pools` で別プールとして足す。

## 5. ハードコードと非再現性を排除する（ただし pin は別）

- region / account / instance type / model tag / quant / node-role は**全て変数化**。
  本文コマンドに実 namespace / IP / account を書かない（`terraform output` から取る）。
- 一方で **再現性のための pin は必須**: ComfyUI バージョン、custom node の ref、モデルの
  HF revision、ワークフローの commit sha、コンテナイメージの digest は固定する。
  「変数化」と「再現性」を混同しない — 変えられるが既定は固定、が正解。
- **起動時 pip / apt を禁止**。依存はイメージに焼き込む。

## 6. weights はイメージに焼かない

- MiniMax-H3 の約 40GB はイメージ非同梱。共有ファイルシステム（OpenZFS `/shared`）に
  `model-fetch` Job で一度だけ取得し、Pod 再起動で使い回す。fetch は冪等（存在ファイルは skip）。

## 7. 手順の正直さ

- 検証できない socket 名で API ワークフローを捏造しない。UI 形式テンプレは UI の
  Save (API Format) で1回変換する、という最小の手動操作を明示する。
- 実機未検証の項目は「未検証」と `docs/PROJECT_STATUS.md` に明記する。症状消失を成功と呼ばない。

## コーディング規約

- Terraform: `terraform fmt` 準拠。変数は base module の命名・description スタイルに合わせる。
- Helm: base module の `charts/experiments` の idiom（`_helpers.tpl` の namespace/claim 解決、
  `fail` ガード、`--set <workload>.enabled=true` トグル）を踏襲。
- ドキュメント/コード/README は英語（repo 規約）。会話とこの docs/ の一部日本語補足は可。
- 絵文字禁止（コード・Markdown とも。Zenn frontmatter を除く）。
