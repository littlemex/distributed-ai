# ComfyUI + MiniMax-H3 実装状況

**最終更新**: 2026-08-10
**プロジェクト開始**: 2026-08-10

## 総合進捗

コード一式は実装・ローカル検証済み（Terraform validate/fmt、helm lint/template、
Python/bash 構文チェックを通過）。**実 AWS への apply はまだ行っていない**（ユーザーが
一括デプロイする段階）。

### 実装完了状況

| コンポーネント | 状態 | ローカル検証 |
|---|---|---|
| Terraform root module (`terraform/`) | 完了 | `terraform init/validate/fmt` 通過。`../../infra/eks` を child module として参照、state 分離を確認 |
| ComfyUI ECR repo (`comfyui-image-builder.tf`) | 完了 | validate 通過。repo を1つ作り ARN を module に渡すだけ。IAM は base 側(貢献済みの汎用変数)が管理 |
| infra/eks への upstream 貢献 | 完了 | `image_builder_additional_ecr_repository_arns` 変数 + check block + validation、builder identity output 4つ、README セクション。後方互換 byte-identical を検証済み。fmt/validate 通過 |
| ComfyUI イメージ (`image/comfyui/Dockerfile`) | 完了 | ComfyUI v0.31.0 pin、起動時 pip 無し、weights 非同梱。実ビルドは未 |
| Helm chart `charts/comfyui` (3 workload) | 完了 | `helm lint` 0 failed、3 workload の template レンダリング確認、fail ガード確認 |
| 動画ワークフロー (`workflows/`) | 完了 | 公式 T2V/I2V を commit 固定で取得。UI→API 変換は UI 上の1回操作として明文化 |
| スモーク実行スクリプト (`scripts/`) | 完了 | `run_smoke.py` py_compile 通過・UI 形式拒否を確認、`port-forward.sh` 構文 OK |
| ドキュメント (`docs/`, README) | 完了 | 本 3 点 + README + 各 chart/workflow README |

### 実機検証（apply 後にやること）

| 検証 | 状態 |
|---|---|
| `terraform apply` で us-west-2 にクラスタ生成 | 未 |
| BuildKit で ComfyUI イメージを ECR に push | 未 |
| MiniMax-H3 weights (~40GB) を OpenZFS に取得 | 未 |
| g6e ノードに ComfyUI Pod が着地・起動 | 未 |
| L40S 48GB で H3 が VRAM に乗る（要 sequential offload） | 未（最大の未知数） |
| T2V ワークフローで動画1本生成・回収 | 未 |

## 主要な設計事実（確定済み）

- **MiniMax-H3 = 33B の image/text-to-video + audio モデル**。ComfyUI **core** がネイティブ対応
  （第三者 GGUF/wrapper ノード不要）。Comfy-Org が事前量子化済みweightsを配布。
- **weights 合計約 40GB**: DiT int8 19.5GB + Qwen3-VL-32B text encoder nvfp4 14.6GB +
  video VAE 4.9GB + audio VAE 0.6GB。
- **g6e.2xlarge = L40S 48GB / 32GiB RAM**、g6e.4xlarge = 同 GPU / 128GiB RAM（offload に有利）。
- **us-west-2 On-Demand G quota = 768 vCPU**（day-one のクォータ障害なし）。g6e.2xlarge = 8 vCPU。

## 未解決リスク / 次アクション

1. **VRAM 収支が最大の未知数**（Fable 指摘）。48GB に 40GB を load しつつ text encoder +
   video VAE decode の activation を収めるのはギリギリ。apply 前に g6e を1台 EC2 で借りて
   30分だけ H3+ComfyUI を実動作確認する、が最もコスト効率が良い一手（任意）。対策済みの逃げ道:
   `comfyui.extraArgs=--lowvram`、`g6e.4xlarge` へフォールバック。
2. **UI→API 形式変換**は UI 上の1回操作が必要（公式テンプレが subgraph 入り UI 形式のため）。
   ブラインドで API graph を捏造しない方針。
3. 実 apply → 生成までは `docs/GETTING_STARTED.md` の手順に従う。

## Fable 実装レビュー(2026-08-10)反映済み

Fable の敵対的レビューを実施し、指摘を全て反映した:

- **memory 収支**: g6e.2xlarge=64GiB(32GiB は誤り)を確認、`comfyui.memory` を 24Gi→48Gi に
  修正(text encoder 15GB + shm + page cache + buffers を OOM せず収める)。
- **torch 未 pin**: Dockerfile で `torch==2.6.0+cu124` 等を pin(ComfyUI は torch を pin しない)。
  ComfyUI は v0.31.0 実在を git ls-remote で確認し **v0.31.1** に更新、Manager を **4.2.2** に更新。
- **run_smoke.py の prompt 上書き**: positive/negative 両方を潰すバグを修正。複数 text ノード時は
  `--prompt-node` を要求、`--list-text-nodes` を追加。/history 未出現時は /queue で存在確認。
- **model-fetch の runtime pip 矛盾**: ComfyUI イメージ(hub 焼き込み)を再利用、期待サイズ検証、
  staging/.hf-cache クリーンアップ、revision 変更検出を追加。
- **IAM role 参照**: 当初は文字列決め打ち→`data "aws_iam_role"`→**最終的に base 貢献で解消**。
  消費者は ARN を渡すだけになり、この root から IAM 参照・管理コードが消えた(責務が base に収束)。
- **destroy ハング**: pool に `termination_grace_period=10m` を追加 + runbook に Deployment 先行削除。
- **probe/imagePullPolicy**: `/system_stats` に変更(lazy load 前提を正しく反映)、`Always` 明示。
  input/user subPath マウント追加、冗長 args 削除。
- **us-west-2 On-Demand G quota = 768 vCPU** を確認済み(day-one 障害なし)。

Fable が「典型」とした v0.31.0 タイポ疑いは誤りで、実在タグだった(v0.31.1 が最新)。

## 残る唯一の実機未知数

**VRAM/RAM 収支の実挙動**。48GB VRAM に H3 を load しつつ text encoder(CPU offload)+ video VAE
decode を回すのは設計上収まるはずだが、実機未検証。逃げ道は実装済み(`comfyui.extraArgs=--lowvram`、
`gpu_instance_types` に g6e.4xlarge fallback、`comfyui.memory` を 96Gi へ)。apply 前に g6e 1台で
30分の事前確認をするのが最もコスト効率が良い(任意)。

## 次のステップ（優先度順）

1. （任意・推奨）g6e 1台での H3+ComfyUI 動作事前確認(最大の未知数を潰す)。
2. `terraform apply` → イメージビルド → weights 取得 → deploy → 動画1本生成
   （`docs/GETTING_STARTED.md` の手順どおり）。
