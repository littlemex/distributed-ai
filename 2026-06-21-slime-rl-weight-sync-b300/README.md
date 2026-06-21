# SLIME RL Post-Training の Weight Sync on Amazon EKS + NVIDIA B300

NVIDIA B300 (Blackwell, sm_103) を使った Amazon EKS 上で、RL post-training フレームワーク
[SLIME](https://github.com/THUDM/slime) (Megatron-LM 訓練 + SGLang rollout, GRPO) を動かし、
**train→rollout の weight 同期 (weight sync) を colocated / disaggregated の 2 方式で実測**した記録。

リファレンスは [awslabs/awsome-distributed-ai の slime test case](https://github.com/awslabs/awsome-distributed-ai/tree/main/3.test_cases/pytorch/slime) (H100/p5 想定)。これを B300 (sm_103) で動かすために特定した壁と対処、weight sync の実測値をまとめる。

## 計測サマリ (weight sync = train→rollout の重み転送 1 回の所要時間)

**apple-to-apple 測定 (2026-06-21)**: 方式・規模の差を交絡なく比較するため、全セルで
**engine 数=4・mem-fraction=0.5・GRPO ハイパラ固定**にした対照実験。

| セル | モデル | 方式 | 実装 | weight sync (定常) |
| --- | --- | --- | --- | --- |
| A1 | Qwen3-4B (dense) | colocated | UpdateWeightFromTensor (CUDA IPC) | **~1.5s** |
| A2 | Qwen3-4B (dense) | disaggregated | UpdateWeightFromDistributed (NCCL/EFA) | **~0.3s** |
| B1 | Qwen3-30B-A3B (MoE) | disaggregated | UpdateWeightFromDistributed (NCCL/EFA) | **~10.1s** (初回 13.1s) |

- ★ **方式軸 (A1 vs A2)**: engine 数・mem-fraction を揃えても、定常状態は disaggregated (0.3s) が
  colocated (1.5s) より **約 5 倍速い** (直感に反する)。原因は転送経路の per-step オーバーヘッド差
  (colocated の CUDA IPC は chunk ごとの `ipc_collect()` GC + Ray IPC handle 往復、disaggregated は
  NCCL 一括 broadcast)。条件を揃える前の初期測定 (engine 2/4・mem 0.4/0.8) でも同傾向 (約 4 倍) で、
  **逆転は構成差でなく転送メカニズム差**であることを確認。詳細は [results/WEIGHT_SYNC_RESULTS.md](./results/WEIGHT_SYNC_RESULTS.md)。
- ★ **規模軸 (A2 vs B1)**: 方式・engine 数を揃えたまま規模だけ変えると、30B MoE は dense 4B の
  **約 34 倍** (10.1s vs 0.3s)。weight sync は転送パラメータ量に強く依存する。
- 30B MoE を SGLang 0.5.12 で回すには `--sglang-moe-runner-backend triton` が必須
  (デフォルト flashinfer_trtllm の swizzled レイアウトが online weight update と非互換、SLIME issue #2091/#1840 と同根)。
- 再現手順は [bench/BENCH-DESIGN.md](./bench/BENCH-DESIGN.md) (3 セルの揃えた条件・実行スクリプト・実測値)。

## ディレクトリ

```
2026-06-21-slime-rl-weight-sync-b300/
├── setup/            # Dockerfile (NGC pytorch 26.02 + TE 2.12 + SGLang 0.5.12), buildkit-job
├── recipe/           # run_grpo.sh (COLOCATE で colocated/disaggregated 分岐), raycluster.yaml
├── env/              # env_vars 3 構成 (colocated-4b / disaggregated-4b / disaggregated-30b-moe)
├── bench/            # apple-to-apple ベンチ (方式×規模マトリクス): env.A1/A2/B1, run/collect スクリプト, BENCH-DESIGN.md
├── results/          # weight sync 実測値 (apple-to-apple 含む)、MoE shape mismatch の root cause 証拠
├── debug-patches/    # SGLang に shape ログを仕込む調査用 patch (再調査用)
├── PATCH-DESIGN.md   # B300 対応の層別 patch 設計と切り分け全履歴
└── COMPLETE-GUIDE.md # 壁ごとの真因・再現手順・ハマりどころ早見表
```

> `bench/` のスクリプト・env は akazawt の検証環境 (namespace `akazawt-slime`、FSx `/fsx/akazawt/...`) の
> パスを含む。各自の環境では namespace・FSx パスを置き換えて使う (env/ と同方針)。

## 検証環境

- EKS / p6-b300.48xlarge x2 (NVIDIA B300, 8 GPU/node, sm_103, EFA 16/node), kai-scheduler, FSx Lustre
- image: `nvcr.io/nvidia/pytorch:26.02-py3` (PyTorch 2.11 / CUDA 13 / TransformerEngine 2.12) を base に
  SLIME v0.2.4 + Megatron-LM + SGLang 0.5.12.post1 を**無改変ビルド** (+ numpy<2 / mbridge の最小追加)
- モデル: Qwen3-4B (dense), Qwen3-30B-A3B (MoE), GRPO on dapo-math-17k / aime-2024

## 特定した壁 (すべてリファレンスの抜け、詳細は COMPLETE-GUIDE.md)

| 層 | 壁 | 対処 |
| --- | --- | --- |
| image | TE 不在で L3 patch 8 個必須 | NGC base (TE 2.12 同梱) を無改変ビルド → L3 patch 全廃 |
| recipe | MODEL_ARGS が渡らない | bash 配列の literal 展開 (RayCluster の shell ネスト差) |
| env | SGLang HTTP server が立たない | `--sglang-log-level WARN` が uvicorn KeyError → `info` |
| env | CUDA graph capture が遅い | B300 大 HBM の `cuda_graph_max_bs` 肥大 → `--sglang-cuda-graph-max-bs 8` |
| env | TP>1 で gloo broadcast hang | `GLOO_SOCKET_IFNAME=eth0` |
| env | train worker 即死 | offload 時の cu12 .so LD_PRELOAD → `--no-offload-train/rollout` |
| image | Megatron が numpy 2.x で abort | Dockerfile に `numpy<2` pin |
| image | MoE 変換が mbridge 不在で失敗 | Dockerfile に mbridge 追加 |
| env | MoE expert weight sync が 400 | flashinfer_trtllm swizzled 非互換 → `--sglang-moe-runner-backend triton` |

## 参考

- SLIME: https://github.com/THUDM/slime
- awsome-distributed-ai slime test case: https://github.com/awslabs/awsome-distributed-ai/tree/main/3.test_cases/pytorch/slime
- 関連 SLIME issue: [#2091](https://github.com/THUDM/slime/issues/2091) (Qwen MoE が SGLang 0.5.12 で 2 回目 rollout 異常), [#1840](https://github.com/THUDM/slime/issues/1840) (GPT-OSS expert weight format)
