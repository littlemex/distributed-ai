# miles 版への移植メモ

slime の training-inference mismatch 検証 (親ディレクトリ) を、slime の直系フォークである
[miles](https://github.com/radixark/miles) で再現するための移植記録。miles は slime を fork point
`fcce96ca0` (2025-10-05) から大きく分岐した別フレームワーク (train loop が sync -> async に全面
書き換え) だが、**train.py の CLI インターフェースと mismatch 検証フラグは互換**であることを確認した。

## なぜ miles か

- miles は CUDA 13.0.1 / PyTorch 2.11 / Blackwell (sm_103) を first-class にターゲットする。slime 版が
  NGC ベース + 手パッチで sm_103 に対応させていたのに対し、miles 公式イメージは sm_103 の
  Transformer Engine FA2 whitelist patch を適用済みで、B300 適合性の素性が良い。
- fp8 rollout / fully-async / true-on-policy など slime にない機能を持つ (本検証の範囲外だが将来の題材)。

## Docker 戦略 C: miles 公式イメージ + EFA 層

miles の依存 (sglang-miles fork の weight sync HTTP endpoint、radixark/Megatron-LM fork、
prebuilt flash_attn/TE/apex wheels) は PyTorch 2.11 stable + cu130 ABI でビルドされており、NGC ベース
(nightly ABI) には載らない。そこで **miles 公式イメージ `radixark/miles:<dated-tag>` をベースにし、
AWS EFA スタックだけを上に足す** (setup/miles.Dockerfile)。追加は ~80 行:

- IB libverbs 除去 (EFA installer の libfabric を優先させる)
- gdrcopy (GPUDirect RDMA)
- EFA installer 1.48.0 (`--skip-kmod`, libfabric + aws-ofi-nccl plugin)
- `FI_PROVIDER=efa` 等の NCCL/EFA runtime env、`GLOO_SOCKET_IFNAME=eth0`
- `PYTHONPATH=/root/miles:/root/Megatron-LM` (miles はこれをイメージに焼かないため明示)

タグは `:latest` を避け `dev-202607182122` (cu13) を pin (awsome-distributed-ai CONTRIBUTING 準拠)。

## slime -> miles の変更点 (recipe / launcher)

| 対象 | slime | miles |
| --- | --- | --- |
| miles/slime 本体 | `/opt/slime` | `/root/miles` (editable install) |
| Megatron | `/opt/Megatron-LM` | `/root/Megatron-LM` (radixark fork) |
| recipe runtime-env PYTHONPATH | `/opt/Megatron-LM` | `/root/Megatron-LM:/root/miles` |
| launcher `SLIME_DIR` default | `/opt/slime` | `/root/miles` (変数名は保持) |
| モデルスクリプト | `scripts/models/qwen3-4B.sh` | 同じ (パス互換) |

train.py に渡すフラグは**無変更**。

## mismatch 検証フラグの互換性 (確認済み)

miles の `miles/utils/arguments.py` に、本検証で使う全フラグが slime と同じ名前・意味で存在する:

- `--get-mismatch-metrics` (計測のみ、loss 不変)
- `--custom-tis-function-path` (ドット/`file.py:func` 記法とも `examples.train_infer_mismatch_helper.mis.compute_mis_weights_with_cp`)
- `--custom-config-path` (TIS/RS パラメータ YAML)
- `--use-tis` / `--use-rollout-logprobs` (排他。miles でも同じ assert)
- `--get-mismatch-metrics` は `--custom-tis-function-path` を要求する assert も同一

miles には `examples/train_infer_mismatch_helper/{mis.py,mis.yaml}` が slime と同一内容で存在するため、
親ディレクトリの `configs/*.yaml` はそのまま流用できる。SGLang passthrough (`--sglang-kv-cache-dtype
fp8_e5m2` 等) も slime と同じく ServerArgs 自動 expose 方式で通る。

### miles ネイティブの TIS 経路 (差分、参考)

miles は上記の slime 互換経路に加え、`loss_hub/corrections.py` に first-class な TIS 実装
(`vanilla_tis_function`, `icepop_function`) を持ち、`--tis-clip` / `--tis-clip-low` で直接制御できる。
本検証は slime との対照を厳密にするため slime 互換経路 (`--use-tis` + `custom-config-path`) を使う。

## 実機検証で最初に潰すべきリスク (REPORT より)

1. EFA installer 1.48.0 x CUDA 13.0.1 (nvidia/cuda ベース) の組合せ。slime 版は NGC 26.02 (CUDA 13.1)
   で検証済みだがベースが変わるため要再確認。
2. weight sync の疎通。`begin_weight_update` / `end_weight_update` / `pull_weights` は
   (当初の調査メモが書いた SGLang fork の HTTP endpoint ではなく) miles 本体の rollout engine
   Ray actor のメソッド (`miles/backends/sglang_utils/sglang_engine.py`) として実装され、
   trainer 側 (`update_weight/common.py`) が `engine.<method>.remote()` で呼ぶ構造だった (smoke で確認)。
3. torch_memory_saver cu13: `--colocate` で offload_train が implicit に有効化され LD_PRELOAD 経路が
   必ず通る。miles はソースビルドなので問題は起きない見込みだが初回 smoke で確認。
4. `CUDA_DEVICE_MAX_CONNECTIONS=1` の要否 (miles の run スクリプトは常時設定)。

## 実機 smoke で判明した落とし穴 (2026-07-19)

### CUDA compat の shadowing で torch.cuda が死ぬ (Error 803)

slime.Dockerfile の EFA 層をそのまま持ち込むと `ENV LD_LIBRARY_PATH=...:/usr/local/cuda/compat:...`
も入る。これが miles ベースでは致命的:

- miles ベースイメージ同梱の CUDA forward-compat libcuda は `580.82.07`。
- 検証ノードの host NVIDIA driver は `580.159.03` (nvidia-smi は "CUDA Version: 13.0" 表示)。
- CUDA forward-compat は「compat >= host driver」でないと使えない。compat (580.82.07) が host
  driver (580.159.03) より古いのに LD_LIBRARY_PATH で優先されると、torch.cuda が
  `RuntimeError: CUDA ... Error 803: system has unsupported display driver / cuda driver
  combination` で死ぬ。SGLang engine 起動時に `get_device()` が "No accelerator available" で落ちる。
- 実証: LD_LIBRARY_PATH から compat を除くと `torch.cuda.is_available() == True` に回復。
- 対処: miles.Dockerfile では **compat を LD_LIBRARY_PATH に入れない**。host driver
  (`/usr/lib64/libcuda.so`) が本イメージの CUDA 13.0 toolkit を既にサポートしているので、そのまま
  解決させる。slime (NGC) が compat を使えたのは NGC の compat が新しかったため。
- 教訓: 「EFA 層を別ベースに移植する」際、CUDA compat の ENV は無検証で持ち込まない。
  ベースの compat バージョンと対象ノードの driver バージョンの大小を必ず確認する。

## 残パッチ (slime 版の 7 修正のうち miles で残るもの)

- `--sglang-log-level warning` (小文字。uvicorn の KeyError 回避、recipe 記述のみ)。
- GPU-less Ray driver での Megatron validate_args CUDA probe (30B MoE で発現しうる。radixark fork で
  直っている可能性もあり要検証)。

numpy<2 pin、torch_memory_saver preload の .so 選択、mbridge の手動 pin は miles 公式イメージで解決済み。
