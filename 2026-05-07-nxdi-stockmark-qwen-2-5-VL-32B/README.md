# nxdi / stockmark-qwen-2-5-VL-32B (2026-05-07)

**AWS Trainium2 (trn2.3xlarge) + NxD Inference で
[`stockmark/Stockmark-DocReasoner-Qwen2.5-VL-32B`](https://huggingface.co/stockmark/Stockmark-DocReasoner-Qwen2.5-VL-32B)
の text backbone を compile し、HF CPU と同等品質のテキスト生成 (日英) を実現するサンプル。**

| 項目 | 値 |
|---|---|
| モデル | `stockmark/Stockmark-DocReasoner-Qwen2.5-VL-32B` (bf16, 64 layers, hidden=5120, GQA 40Q/8KV, rope=1e6, M-RoPE) |
| ハードウェア | trn2.3xlarge (Trainium2 × 4 chip = 8 physical NeuronCore, LNC=1, TP=8) |
| Neuron SDK | 2.29 系 + `torch_neuronx >= 2.9` + NxD/NxDI GitHub main |
| transformers | 4.51.3 〜 4.57.x (Qwen2.5-VL 対応) |
| probe cos (prefill, full 64L) | **0.999938** |
| multi-prompt sanity (6 prompts) | **A-WIN 6/6 non-degenerate**、avg greedy token match **93.75%** |

## 実測: 生成品質

HF CPU greedy と NxD Neuron greedy を同じ prompt / generation_config で比較:

| prompt | HF CPU text | NxD Neuron text | token match |
|---|---|---|---|
| `The capital of France is?` | `<think> The question asks for the capital of France. To answer this,` | **完全一致** | 16/16 |
| `What does AWS Trainium accelerate?` | `<think> The question asks what AWS Trainium accelerates. To answer this` | **完全一致** | 16/16 |
| `What color is the sky?` | `<think>The question asks about the color of the sky. To answer this,` | `<think>The question asks for the color of the sky. To answer this,` | 15/16 |
| **`日本の首都はどこですか。`** | `<think>質問は「日本の首都はどこですか。」です。` | **完全一致** | 16/16 |
| **`富士山の高さは何メートルですか。`** | `<think>質問は「富士山の高さは何メート` | **完全一致** | 16/16 |
| **`猫の鳴き声を教えてください。`** | `猫の鳴き声は「にゃーにゃー」です` | `猫の鳴き声は「にゃー」となります。` | 11/16 |

**日本語モデルとしての実用品質**: 完全動作。違いは BF16 の tie-break と丁寧体 ("です" vs "となります") 程度。

## ファイル構成

```
2026-05-07-nxdi-stockmark-qwen-2-5-VL-32B/
├── README.md
├── code/
│   ├── modeling_stockmark_text.py   NxD 派生 modeling (Qwen2.5-VL text backbone)
│   ├── compile_and_test.py          compile + probe cos + 1-prompt generate driver
│   ├── sanity_generate.py           multi-prompt sanity (日英 6 prompts)
│   ├── sbatch-compile.sbatch        1-layer smoke test Slurm job
│   ├── sbatch-compile-full.sbatch   full 64-layer Slurm job
│   └── sbatch-sanity.sbatch         sanity-only Slurm job (NEFF 再利用)
└── results/
    ├── metrics-64l.json             full 64-layer 実測値
    └── sanity-generate.json         6 prompt generation 実測値
```

## なぜ NxD 派生実装が必要か (一言)

Stockmark-DocReasoner-Qwen2.5-VL-32B は `torch_neuronx.trace()` の **primitive path では動きません**:

- **GQA 5:1** (40 Q / 8 KV) で KV cache shard に制約
- **rope_theta=1e6** で BF16 inv_freq が underflow
- **Multimodal RoPE** (`mrope_section=[16,24,24]`) で 3 軸 tensor_split

NxDI の既存 Qwen2-VL text backbone を Qwen2.5-VL 用に fork + 右パディング NxDI native pattern に揃えると、probe cos≈1 + 実生成でも HF と同等に動きます。

## 前提

- trn2.3xlarge が使えるクラスター (ParallelCluster + Slurm 想定、単機でも可)
- `/opt/neuron_venv` (Neuron SDK 2.29 DLAMI デフォルト)
- Hugging Face token (`HF_TOKEN`、公開モデルでも rate limit 回避のため)
- `/home` に **150 GB 以上の空き** (full 64L で HF snapshot 63 GB + NEFF caches)

## エンドツーエンド手順

```bash
# 1. 作業ディレクトリを作る
export EXP_DIR=$HOME/stockmark-docreasoner-nxdi
mkdir -p "$EXP_DIR"
cp -r 2026-05-07-nxdi-stockmark-qwen-2-5-VL-32B/code "$EXP_DIR/"

# 2. HF token を設定
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxx

# 3. 1-layer smoke test (~3 min + 初回 HF download ~10 min)
sbatch \
  --output="$EXP_DIR/results/%x-%j.out" \
  --error="$EXP_DIR/results/%x-%j.err" \
  --export=ALL,EXP_DIR="$EXP_DIR",HF_TOKEN="$HF_TOKEN",NUM_LAYERS=1 \
  "$EXP_DIR/code/sbatch-compile.sbatch"
# → results/metrics-1l.json の probe_cos > 0.99 を確認

# 4. full 64-layer (~10 min)
sbatch \
  --output="$EXP_DIR/results/%x-%j.out" \
  --error="$EXP_DIR/results/%x-%j.err" \
  --export=ALL,EXP_DIR="$EXP_DIR",HF_TOKEN="$HF_TOKEN" \
  "$EXP_DIR/code/sbatch-compile-full.sbatch"
# → results/metrics-64l.json の probe_cos > 0.99、greedy match 13/16 以上を確認

# 5. (推奨) multi-prompt sanity
sbatch \
  --output="$EXP_DIR/results/%x-%j.out" \
  --error="$EXP_DIR/results/%x-%j.err" \
  --export=ALL,EXP_DIR="$EXP_DIR",HF_TOKEN="$HF_TOKEN" \
  "$EXP_DIR/code/sbatch-sanity.sbatch"
# → results/sanity-generate.json の verdict を確認
# 期待: "A-WIN: all prompts produce coherent (non-looping) generation"
```

## trn2 単機 (stand-alone / 非 Slurm) で動かす場合

```bash
export EXP_DIR=$HOME/stockmark-docreasoner-nxdi
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxx
export HF_HUB_DISABLE_XET=1           # sa-east-1 では必須
export HF_HUB_ENABLE_HF_TRANSFER=1
export NEURON_LOGICAL_NC_CONFIG=1
export NEURON_RT_VISIBLE_CORES=0-7
export NEURON_RT_NUM_CORES=8
export NUM_LAYERS=64

source /opt/neuron_venv/bin/activate
python "$EXP_DIR/code/compile_and_test.py"
python "$EXP_DIR/code/sanity_generate.py"   # NEFF 再利用
```

## 重要な落とし穴と対策 (検証中に踏んだ地雷)

### 1. **`HF_HUB_DISABLE_XET=1` は必須** (sa-east-1)

2026 年春の HF は LFS 後継の `xet` がデフォルト。`hf_transfer=1` でも内部で xet に倒れるケースがあり、sa-east-1 からは **< 1 MB/s** に落ちます (実測: 1.5 GB / 46 分で timeout)。`HF_HUB_DISABLE_XET=1` で plain HTTPS に戻して ~100 MB/s に復帰。

### 2. **transformers 4.52+ の `text_config` + `layer_types` 二重管理**

`num_hidden_layers=1` だけ書き換えても `text_config.layer_types` が元の 64 のまま残り validation エラー。両側を同期 truncate する必要がある (本サンプル `compile_and_test.py` の `_truncate_layers` 参照)。

### 3. **NxDI は `padding_side="right"` が native pattern** ⭐ 最重要

当初我々は `neuron_config.padding_side="left"` + 事前 left-pad でテストしていましたが、日本語テキスト生成が `"質問われてきょ"` のように破綻しました。原因:

- NxDI の `ModelWrapper.pad_inputs()` は **常に右詰め** (`neuron_config.padding_side` を参照しない)
- `NeuronBaseModel._create_simple_attn_mask()` (TKG 用) は attention_mask の 0 ビットを slot mask に使うので右詰め前提
- **`padding_side="left"` にすると CTE と TKG で mask 方向が矛盾**

対策: `neuron_config.padding_side="right"` + **事前 padding をせず raw prompt を adapter に直接渡す**。pad_inputs が自動で右詰めし、NEFF も右詰めで compile されているので一致。これで日本語も英語も HF CPU と同等に動きます。

### 4. **`NeuronAttentionBase.apply_rotary_embedding` は override しない**

当初 `apply_multimodal_rotary_pos_emb` を別途呼ぶ override を書いていましたが、NxDI のレイヤー間 `cos_cache` 引き継ぎと相性が悪く、CTE → TKG で古い cos_cache を使い回す hazard がありました。最終実装では override を削除し、rotary_emb が直接 `[3, B, S]` 用の cos/sin を返す形に統一。NxDI の base class (`apply_rotary_pos_emb`) が自然に処理します。

### 5. **Stockmark-DocReasoner は chat-tuned モデル**

`apply_chat_template` で `<|im_start|>role\n...<|im_end|>` でラップすると品質が上がります (特に日本語)。raw encode でも動きますが思考モード (`<think>`) が起動せず、生成が完結しない傾向。

### 6. **`repetition_penalty=1.05` を推奨**

`generation_config.json` の公式推奨。BF16 の tie-break による同トークン反復を緩和します。

## 実測 metrics

### `results/metrics-64l.json` (抜粋)

```json
{
  "num_layers": 64, "tp_degree": 8, "dtype": "bfloat16",
  "padding_side": "right",
  "compile_time_sec": 278.32,
  "probe_cos": 0.999938, "probe_top1_match": 1,
  "gen_token_match": 14, "gen_token_total": 16,
  "gen_cpu_text": "Trainium is an AWS chip that accelerates machine learning training\n\nAWS has announced Trainium, ...",
  "gen_nxd_text": "Trainium is an AWS chip that accelerates machine learning training\n\nAWS is announcing Trainium, ...",
  "verdict": "A: mostly aligned (probe cos + >=80% greedy match)"
}
```

### `results/sanity-generate.json` (抜粋)

```json
{
  "verdict": "A-WIN: all prompts produce coherent (non-looping) generation",
  "n_prompts": 6, "n_non_degenerate": 6,
  "avg_greedy_match_rate": 0.9375
}
```

## 次の拡張

- Vision encoder NEFF を追加 (`NeuronBaseForImageToText` 継承) → 真の VLM 推論
- multi-bucket (`buckets=[32, 64, 96, 128]`) で短 prompt の高速化
- `on_device_sampling_config` で sampling を Neuron 側に寄せる

## ライセンス

コードは Apache-2.0 (NxDI 由来は Amazon.com, Inc. 著作権、Qwen2-VL 由来は Alibaba/Qwen team)。
配布の際は各アップストリームのライセンスに従ってください。
