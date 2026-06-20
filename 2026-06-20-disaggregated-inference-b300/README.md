# Disaggregated Inference on Amazon EKS + NVIDIA B300

NVIDIA B300 (Blackwell, sm_103) を使った Amazon EKS 上で、LLM の
disaggregated inference (prefill/decode 分離 + KV キャッシュ転送) を
vLLM native と llm-d の両方で構築・計測した記録。

## ブログ

- [前編: 理論編](./blog/01-theory.md) — なぜ分離するのか、要素技術 (PD分離 / KV cache / NIXL / EFA / GIE+EPP)、実測結果のグラフと観測
- [後編: 実践編](./blog/02-practice.md) — EKS 構築手順、B300 のハマりどころ、コード解説

## ディレクトリ

```
2026-06-20-disaggregated-inference-b300/
├── blog/        # 前編・後編 (Zenn 記法 Markdown)
├── figs/        # 実測グラフ (PNG)
├── results/     # goodput 計測の生 CSV
├── setup/       # Dockerfile, env_vars, ECR/S3 policy
├── manifests/   # vLLM native の k8s manifest (prefill/decode/proxy/buildkit/benchcli)
├── recipe/      # 計測データ収集スクリプト (collect-to-s3 など)
└── llm-d/       # llm-d 用 kustomize overlay (Qwen3-8B / DeepSeek-V3, B300+EFA patch)
```

## 計測サマリ (1P+1D = 16 GPU, goodput = P90 TTFT/TPOT が SLO 内の最大レート)

| モデル | shape | vLLM native | llm-d | 備考 |
| --- | --- | --- | --- | --- |
| Qwen3-8B | chat | 32+ (未飽和) | 32+ (未飽和) | 軽量・低負荷では同等 |
| Qwen3-8B | long-context | 16+ (未飽和) | 16+ (未飽和) | 同等 |
| DeepSeek-V3 671B | chat | 32+ (未飽和) | 32+ (未飽和) | 同等 (TP8) |
| DeepSeek-V3 671B | long-context | rate6 で P90 TTFT 崩壊 | rate16+ でも安定 | ★ ルーティング層で数倍差 |

- 数値は計測した Poisson レート範囲での値。「未飽和」= sweep 上限まで SLO を満たし飽和点は範囲外。
- 全構成で KV 転送は NIXL / libfabric over EFA。詳細は前編・後編を参照。

## 検証環境

- EKS 1.35 / p6-b300.48xlarge x N (NVIDIA B300, 8 GPU/node, EFA 16/node)
- vLLM 0.21.0 + NIXL + UCCL-EP (sm_103/cu13 自前ビルド)
- llm-d v0.7.0 + Gateway API Inference Extension v1.5.0
