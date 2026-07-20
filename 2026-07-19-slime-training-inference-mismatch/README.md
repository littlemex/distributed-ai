# SLIME GRPO の Training-Inference Mismatch 検証 on Amazon EKS

RL post-training フレームワーク [SLIME](https://github.com/THUDM/slime) (Megatron-LM 訓練 +
SGLang rollout, GRPO) を Amazon EKS 上の単一 GPU ノード (H200 x8) で動かし、論文
「Beyond Precision: Training-Inference Mismatch is an Optimization Problem and Simple LR
Scheduling Fixes It」(arXiv:2602.01826) の主張を検証した記録。

リファレンスは [awslabs/awsome-distributed-ai の slime test case](https://github.com/awslabs/awsome-distributed-ai/tree/main/3.test_cases/pytorch/slime)。
本ディレクトリはそこに対する **最小の汎用 hook 追加 (recipe) と、mismatch 検証専用の環境変数
サンプル・config・結果ドキュメント** をまとめたもので、upstream の test case 本体は変更しない。

## 一行結論

論文の主張 (rollout/trainer の logprob mismatch が学習崩壊を招き、適切な補正で治る) は正しい。
ただし崩壊が顕在化するかは mismatch の絶対量 (mis_kl) 次第で、それは rollout エンジンと trainer の
数値経路差で決まる。素の bf16 SGLang vs Megatron では mis_kl ~6e-4 と極小で崩壊しない (良性) が、
rollout の KV cache を fp8 に量子化して mismatch を 54 倍に増幅すると、bf16 では安定だった学習率
でも崩壊する。cap 付き importance sampling (TIS) で救済できる。

詳細な因果構造と数値は [docs/RESULTS.md](./docs/RESULTS.md)。

## 検証の骨子

1. **baseline (bf16)**: mis_kl ~6e-4 と極小。LR を上げて崩壊させても mismatch は増幅しない。
2. **amplified (KV fp8)**: rollout の KV cache を fp8_e5m2 に量子化し mis_kl を ~3e-2 に増幅。
   bf16 では安定な LR 1e-5 で、mis_kl が指数発散し遅れて reward/entropy が崩壊する
   (mismatch が崩壊を駆動する論文の因果を再現)。
3. **TIS (救済)**: 同じ設定に cap 付き importance sampling を適用すると崩壊を回避し reward が上昇。
   cap を無効化 (mis_nocap.yaml) すると崩壊する = cap こそが救済の因果因子。

崩壊機序は 2 種類あり、entropy の動く向きで区別できる (bias 駆動は entropy 低下、variance 駆動は
entropy 上昇)。詳細は [docs/RESULTS.md](./docs/RESULTS.md) の bias-variance の節。

補足: 検証中に観測された ppo_kl ~0.30 は mismatch ではなく train モードの dropout が原因だった
([docs/PPOKL_ROOTCAUSE.md](./docs/PPOKL_ROOTCAUSE.md))。全 run は dropout=0 で回している。

## ディレクトリ

```
2026-07-19-slime-training-inference-mismatch/
├── recipe/
│   ├── run_grpo_qwen3_4b.sh            # upstream recipe + 汎用 hook (下記 patch 適用済み)
│   └── run_grpo_qwen3_4b.hooks.patch   # upstream に対する差分 (EXTRA_TRAIN_ARGS / USE_DYNAMIC_BATCH)
├── env/
│   ├── env_vars.baseline.example       # bf16 baseline (計測のみ、loss 不変)
│   ├── env_vars.amplified.example      # KV fp8 で mismatch 増幅、補正なし (崩壊アーム)
│   └── env_vars.tis.example            # KV fp8 + TIS cap 2.0 (救済アーム)
├── configs/
│   ├── mis.yaml                        # TIS 有効、tis_upper_bound=2.0 (救済用)
│   ├── mis_metrics_only.yaml           # use_tis/use_rs=false (計測のみ、loss 不変)
│   └── mis_nocap.yaml                  # tis_upper_bound=100 (cap 実質無効、対照用)
└── docs/
    ├── RESULTS.md                      # 因果構造・数値・bias-variance 框架・検証の限界
    └── PPOKL_ROOTCAUSE.md              # ppo_kl~0.30 = train-mode dropout の実測確定
```

## 再現手順 (概要)

前提: [awslabs/awsome-distributed-ai の slime test case](https://github.com/awslabs/awsome-distributed-ai/tree/main/3.test_cases/pytorch/slime)
の手順で SLIME イメージ (slime 0.2.4 / SGLang 0.5.12) をビルドし、RayCluster と共有ストレージ
(FSx 等) を用意しておく。モデル (Qwen3-4B の HF checkpoint と Megatron torch_dist) と
データ (dapo-math-17k, aime-2024) は共有ストレージ上に配置する。

1. **recipe の hook を適用**: upstream の `recipe/run_grpo_qwen3_4b.sh` に
   `recipe/run_grpo_qwen3_4b.hooks.patch` を当てる (本ディレクトリの `run_grpo_qwen3_4b.sh` は適用済み)。
   hook は `EXTRA_TRAIN_ARGS` (追加フラグの注入) と `USE_DYNAMIC_BATCH` (診断用に dynamic batch を
   無効化) の 2 点のみで、未設定時は upstream とビット同一の argv になる。
2. **config を配置**: `configs/*.yaml` を共有ストレージの `/fsx/configs/` に置く。
3. **env を選んで実行**: `env/env_vars.{baseline,amplified,tis}.example` のいずれかを `env_vars`
   にコピーし、`HF_TOKEN` と各パスを埋めて、test case の launch 手順で起動する。
4. **観測**: `--use-tensorboard` の event file が `TENSORBOARD_DIR` に書かれる。mis_kl / reward /
   entropy / ppo_kl を追う。

### mismatch 計測フラグの落とし穴

- `--custom-tis-function-path` は **ドット記法のモジュールパス**
  (`examples.train_infer_mismatch_helper.mis.compute_mis_weights_with_cp`) で渡す。README にある
  `file.py:func` 形式では `load_function()` が `rpartition(".")` + `import_module` するため
  ModuleNotFoundError になり、rollout は動くので **train() 開始まで失敗が遅延**する。
- `--get-mismatch-metrics` は計測のみでも `--custom-config-path` を要求する (無いと
  `tis_lower_bound` の AttributeError)。計測専用は `use_tis/use_rs=false` の `mis_metrics_only.yaml`。
- `--use-tis` と `--use-rollout-logprobs` は排他 (TIS は train-side logprob を保持して補正重みを
  乗じる、rollout-logprobs は logprob そのものを置換する)。

### fp8 weight rollout が使えない理由 (実装知見)

mismatch を作る本命だった fp8 **weight** rollout は SLIME 0.2.4 / SGLang 0.5.12 では動かない:
compressed-tensors checkpoint を使う weight sync が叩く SGLang の `/post_process_weights`
エンドポイントが SGLang 0.5.12 に未実装で 404 になる。online `--quantization fp8` は weight sync
時に silent corruption する。そのため weight sync に触れない **KV cache fp8** を増幅装置に採用した。
