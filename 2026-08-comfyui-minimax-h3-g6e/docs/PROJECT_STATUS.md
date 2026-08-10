# ComfyUI + MiniMax-H3 実装状況

**最終更新**: 2026-08-10
**プロジェクト開始**: 2026-08-10

## 総合進捗

**実機で end-to-end 検証完了（2026-08-10, us-west-2）。** apply → in-cluster イメージビルド →
weights 取得 → ComfyUI 起動 → 動画1本生成・回収まで全て成功。単一 L40S(g6e.4xlarge)で
MiniMax-H3(33B)が sequential offload により実際に動くことを確認済み。

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

### 実機検証（2026-08-10 完了）

| 検証 | 状態 |
|---|---|
| `terraform apply` で us-west-2 にクラスタ生成 | 完了（152 resources、約15分） |
| BuildKit で ComfyUI イメージを ECR に push | 完了（v2、torch 2.8.0+cu126、約8-9分、6.7GB） |
| MiniMax-H3 weights (~40GB) を OpenZFS に取得 | 完了（4ファイル、size検証つき、約8.5分） |
| g6e ノードに ComfyUI Pod が着地・起動 | 完了（Karpenter が g6e.4xlarge を選択、Ready） |
| L40S 48GB で H3 が VRAM に乗る（sequential offload） | 完了（text encoder 15GB→DiT 20GB を dynamic staging、ピーク 40.5/46GB、100% util） |
| T2V ワークフローで動画1本生成・回収 | 完了（864x480/5.17s H.264 + AAC音声、初回 10分40秒） |

## 主要な設計事実（確定済み）

- **MiniMax-H3 = 33B の image/text-to-video + audio モデル**。ComfyUI **core** がネイティブ対応
  （第三者 GGUF/wrapper ノード不要）。Comfy-Org が事前量子化済みweightsを配布。
- **weights 合計約 40GB**: DiT int8 19.5GB + Qwen3-VL-32B text encoder nvfp4 14.6GB +
  video VAE 4.9GB + audio VAE 0.6GB。
- **g6e.2xlarge = L40S 48GB(usable ~44.7GiB) / 64GiB RAM**（DescribeInstanceTypes で確認、
  32GiB は誤りだった）、g6e.4xlarge = 同 GPU / 128GiB RAM。実機では Karpenter が fallback から
  **g6e.4xlarge** を選択。
- **us-west-2 On-Demand G quota = 768 vCPU**（day-one のクォータ障害なし）。

## 実機で判明した重要事項（検証の成果）

1. **torch >= 2.7 が必須**（当初 2.6.0+cu124 で pod が起動時 CrashLoop）。ComfyUI v0.31 の
   native `comfy_kitchen` ops が PEP585 `list[int]` 型注釈を使い、torch<=2.6 の infer_schema が
   拒否。→ **torch 2.8.0 + CUDA 12.6.3** に修正済み（commit で push 済み、v2 イメージで検証）。
2. **VRAM 収支は問題なし**（当初の最大懸念は解消）。text encoder(15GB staged)→ DiT(20GB staged)
   を dynamic VRAM staging + CPU offload で順次ロードし、ピーク 40.5/46GB で完走。lowvram も
   4xlarge fallback も発動不要だった（が逃げ道として残す）。
3. **T2V の API ワークフローは core ノードだけで直接記述できた**（公式 UI テンプレの subgraph が
   custom node 依存だったため）。live `/object_info` で全 node の input を検証し、
   `workflows/video_minimax_h3_t2v.api.json` としてコミット。UI 上の Save(API Format) は I2V/R2V
   の場合のみ必要。
4. **image-cache 機構**: base の並列 pull(`maxParallelImagePulls=8`)は g6e ノードに自動適用済み。
   image-prewarm DaemonSet は単一ノード・単一 Pod 構成では不要と判断し未使用（spot 混在/複数
   レプリカに拡張する場合のみ有益）。
5. **build は git fetch 経由**なので `imageBuild.gitRef` は push 済みの ref を指す必要がある
   （runbook に明記済み）。

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
なお torch の pin バージョン(2.6.0)は実機で不足と判明し 2.8.0 に是正(上記「重要事項」1)。

## 既知の軽微事項（動作影響なし）

- **ComfyUI-Manager が import 失敗**(`4.2.2` タグのディレクトリ構成差)。任意機能で H3 生成に不要。
  必要なら Manager の ref を合う版に修正、または `COMFYUI_MANAGER=false` で焼かない。

## 現在の稼働状態 / 運用

- クラスタ `comfyui-minimax-h3`(us-west-2)稼働中、ComfyUI Deployment Running、
  port-forward で `http://localhost:8188`。生成は `docs/GETTING_STARTED.md` 手順どおり。
- **コスト**: g6e GPU ノード + FSx + EKS が課金継続。停止は `kubectl -n comfyui delete deploy comfyui`
  (GPU ノードは consolidation で数分後に落ち、weights は OpenZFS に残る)。全撤去は `terraform destroy`。
