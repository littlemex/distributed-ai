# miles 版: Training-Inference Mismatch 検証

親ディレクトリの slime GRPO mismatch 検証を、slime の直系フォークである
[miles](https://github.com/radixark/miles) で再現した記録。miles は CUDA 13 / Blackwell を
first-class にターゲットする RL post-training フレームワークで、train.py の CLI と mismatch 検証
フラグは slime と互換であることを実機で確認した。

## 到達点 (実機、単一ノード H200 x8, colocated GRPO, Qwen3-4B)

- miles 版イメージ (radixark/miles + EFA 層) をビルドし、GRPO 1 step を完走。
- **miles baseline の mis_kl 0.000632** — slime baseline (~0.00065) とビット近似一致。
- **KV fp8 で mis_kl 0.0310 (約49倍増幅)** — slime の KV fp8 増幅 (54倍) とほぼ一致。
- ppo_kl は dropout=0 で 0.0 (slime の「ppo_kl は dropout artefact」結論を再現)。

結論: 「mismatch の絶対量は RL フレームワーク (slime/miles) でなく rollout/trainer の数値経路差で
決まる」という親ディレクトリの結論が、2 フレームワークで裏付けられた。詳細は [docs/RESULTS.md](./docs/RESULTS.md)。

## ディレクトリ

```
miles-port/
├── setup/
│   ├── miles.Dockerfile     # radixark/miles:<tag> + EFA 層 (戦略C)
│   └── buildkit-job.yaml    # in-cluster buildkit で ECR に push (CPU ノードで実行、GPU 不要)
├── recipe/
│   ├── run_grpo_qwen3_4b.sh # slime 版 recipe を miles パス (/root/miles, /root/Megatron-LM) に調整
│   └── grpo_launch.sh       # SLIME_DIR デフォルトを /root/miles に (変数名は保持)
├── env/
│   ├── env_vars.baseline.example   # bf16 baseline (計測のみ)
│   ├── env_vars.amplified.example  # KV fp8 で増幅、補正なし
│   └── env_vars.tis.example        # KV fp8 + TIS cap 2.0 (救済)
├── configs/                 # mis.yaml / mis_metrics_only.yaml / mis_nocap.yaml (親と同一)
└── docs/
    ├── PORT_NOTES.md         # 移植の要点、実機で判明した落とし穴 (CUDA compat / libcuda / driver 配置)
    └── RESULTS.md            # miles 実測値と slime との比較
```

## 実機で判明した miles 固有の落とし穴 (公開 Dockerfile / manifest に反映済み)

いずれも slime 版 (NGC ベース) では起きず、miles ベース (nvidia/cuda) への移植で顕在化した。
詳細と根拠は [docs/PORT_NOTES.md](./docs/PORT_NOTES.md)。

1. **CUDA compat の shadowing (Error 803)**: miles ベース同梱の forward-compat libcuda が host
   driver より古く、LD_LIBRARY_PATH に入れると torch.cuda が死ぬ。miles.Dockerfile では compat を
   `rm -rf` し、host driver を使う。
2. **libcuda.so.1 が SGLang サブプロセスで見つからない**: driver 注入先 (`/usr/lib64` /
   `/usr/lib/x86_64-linux-gnu`) を LD_LIBRARY_PATH 末尾に足し、ldconfig にも登録する。
3. **driver (ray job entrypoint) が head で libcuda 不在で死ぬ**: miles の actor モジュールが
   mooncake (libcuda 依存) を module-load 時に import する。head は num-gpus:0 で libcuda が無い。
   worker に `gpu_node` カスタムリソースを宣言し、`ray job submit --entrypoint-resources
   '{"gpu_node": 0.001}'` で driver を GPU worker 上で実行する (GPU 論理カウントは消費しないので
   colocated の 8-GPU placement group と衝突しない)。

## 再現手順 (概要)

1. **ビルド**: `setup/miles.Dockerfile` を ConfigMap にし、`setup/buildkit-job.yaml` を
   CPU ノード (十分な ephemeral-storage を持つノード) で実行して ECR に push。GPU は不要。
2. **クラスタ**: KubeRay RayCluster をデプロイ。head は非 GPU ノード、worker は GPU ノードで
   `rayStartParams.resources: '{"gpu_node": 1}'` を宣言。head 用 CPU ノードは EBS >= 100GB gp3
   (イメージ 18GB の展開に必要)。
3. **投入**: `ray job submit --entrypoint-resources '{"gpu_node": 0.001}' --working-dir <recipe>
   -- bash grpo_launch.sh <train.py flags>`。env は `env/env_vars.{baseline,amplified,tis}.example`
   を参照。

前提となる SLIME/miles 共通の RL 設定は親ディレクトリの [README](../README.md) を参照。
