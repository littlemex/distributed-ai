# 日本語 要約 (LLM) / embedding のコスト実測: Graviton CPU vs g6e (L40S) vs API

日本語の **要約 (生成 LLM)** と **embedding (検索/RAG 前処理)** を低コストに回す構成を、
**AWS Graviton3/4 CPU (c7g/c8g)** と **g6e (NVIDIA L40S)** で実測し、
**Amazon Bedrock / OpenAI などの従量 API** とのコスト損益分岐を求めた記録。

計測は「第三者が自分のワークロード (件数 x 平均トークン長) に外挿できる」ことを目標に、
条件を明示した表と派生指標 ($/1M tokens, $/1M sentences) で報告する。方法論は
[`docs/METHODOLOGY.md`](docs/METHODOLOGY.md)。

> スコープ注記: 本実験の主目的は **スループットとコスト** の実測。精度は
> **参考値レベルの sanity check** (日本語が壊れていないか、公表ベンチと桁が合うか) であり、
> 完全な JMTEB / WMT 評価ではない。

## ディレクトリ

```
2026-07-05-ja-summarization-embedding-cost-graviton-g6e/
├── README.md                     # 本ファイル (概要・サマリ・損益分岐)
├── docs/
│   └── METHODOLOGY.md            # 計測条件・手順・報告フォーマットの定義
├── scripts/
│   ├── embedding_throughput.py       # Graviton embedding スループット sweep (ONNX, ruri/e5/gemma)
│   ├── embedding_throughput_gemma.py # EmbeddingGemma 用 (ONNX external-data の flat-dir 対応)
│   ├── embedding_accuracy.py         # 日本語 retrieval 精度 (nDCG@10 / Recall@10)
│   ├── embedding_accuracy_gemma.py   # 同上 EmbeddingGemma 用
│   ├── summarization_throughput.sh   # g6e 要約 total tok/s sweep (vllm bench throughput, random)
│   ├── translation_eval.py           # 翻訳 chrF (JA<->EN, sacrebleu)
│   └── translation_run.sh            # vLLM serve -> translation_eval -> shutdown
└── results/
    ├── summarization_throughput_g6e_L40S.jsonl  # 要約 生データ (入力x出力 sweep)
    ├── summarization_summary.csv                # 要約 集計 (tok/s, $/1M tok)
    ├── embedding_throughput_graviton.jsonl      # embedding 生データ (model x quant x len x batch x host)
    ├── embedding_summary.csv                    # embedding 集計 (sent/s, tok/s, $/1M)
    └── embedding_accuracy_ja_retrieval.jsonl    # embedding 精度 (nDCG@10 / Recall@10)
```

## ハードウェアと単価 (us-west-2 オンデマンド, 2026-07 時点・概算)

| インスタンス | 構成 | $/hr | 用途 |
|---|---|---|---|
| c7g.8xlarge | Graviton3, 32 vCPU | 1.16 | embedding |
| c8g.8xlarge | Graviton4, 32 vCPU | 1.276 | embedding |
| g6e.xlarge (per-L40S 換算) | L40S 48GB x1 | 1.861 | 要約 (1 model = 1 GPU) |

> g6e.12xlarge (L40S x4) を借り、1 モデル=1 GPU で測っているため、要約の $/1M は
> **per-L40S 単価 $1.861/hr** で換算している (= g6e.xlarge 相当)。

---

## 計測サマリ 1: 要約 LLM (g6e, L40S 1枚, continuous batching)

`vllm bench throughput`、入力 256/1024/4096 x 出力 128/512 tokens を厳密統制 (random dataset)。

| モデル | 種別 | 総 tok/s (全条件ほぼ一定) | **$/1M total tokens** |
|---|---|---|---|
| **gpt-oss-20b** | MoE 活性3.6B | 約 18,700 | **0.0275** |
| Qwen3-30B-A3B-Instruct-2507 (FP8) | MoE 活性3.3B | 約 9,680 | 0.0534 |
| Qwen3-14B | dense | 約 4,010 | 0.129 |

**最重要の発見**: 入力長を 256->4096 (16倍) に変えても、出力を 128/512 に変えても、
**総 tok/s はほぼ一定**だった (3モデルとも)。continuous batching が飽和して GPU が常に
トークンを最大処理しているため。よって **要約コストは処理する総トークン数にほぼ比例** し、
`コスト = (総入力tok + 総出力tok) / 1M x $/1M` で、入出力比を気にせず見積もれる。

---

## 計測サマリ 2: embedding (Graviton CPU, ONNX int8, 入力512tok, 最良バッチ)

| モデル | パラメータ | JMTEB(公表) | c8g tok/s | **c8g $/1M input tok** |
|---|---|---|---|---|
| **ruri-v3-30m** | 37M | 74.51 | 約 53,900 | **0.0066** |
| ruri-v3-70m | 70M | 75.48 | 約 29,200 | 0.0121 |
| me5-small (fp32) | 118M | — | 約 22,000 | 0.0161 |
| ruri-v3-130m | 132M | 76.55 | 約 14,800 | 0.0239 |
| **ruri-v3-310m** | 315M | **77.24** | 約 7,100 | 0.0502 |
| embeddinggemma-300m | 308M | (JA弱め) | 約 5,100 | 0.0699 |

- **int8 は fp32 の約 1.5-3x** (例 ruri-310m: 22.6->65.3 sent/s @L128 = 2.9x)。量子化必須。
- **Graviton4 (c8g) > Graviton3 (c7g)** で一貫して約 15-25% 速い。ただし c8g の方が
  時間単価が高いので **$/1M はほぼ互角** (コスパは c7g、絶対速度は c8g)。
- **EmbeddingGemma は本用途では非推奨**: サイズは ruri-130m 級なのに **全モデル中ほぼ最遅**
  (Gemma 系アーキが重い) で、日本語精度も公表値は低め。ruri-v3 系が速度・精度とも上。

### embedding 精度 (日本語 retrieval mini, nDCG@10 / Recall@10)

小規模 (10クエリ/40文書) の sanity check。全モデルが日本語 retrieval で正常動作:
ruri-v3-30m/70m/130m/me5-small/embeddinggemma = nDCG@10 **1.00**、ruri-v3-310m = 0.963。
(タスクが易しく満点続出。目的は「日本語が壊れていない」ことの確認。EmbeddingGemma の
公表 JA スコアの低さは transformers バージョン起因の測定バグ疑義があり、ここでは正常だった。)

---

## 計測サマリ 3: 翻訳 (参考値, chrF, JA<->EN, thinking 無効化後)

要約用 LLM が日本語をどの程度扱えるかの sanity check (5対訳文, chrF via sacrebleu)。
Qwen3 系は thinking を無効化し、`<think>` / gpt-oss harmony reasoning を除去して採点。

| モデル | 日->英 chrF | 英->日 chrF |
|---|---|---|
| **gpt-oss-20b** | **90.7** | 58.2 |
| Qwen3-30B-A3B-Instruct-2507 (FP8) | 78.1 | 54.9 |
| Qwen3-14B | 71.1 | 49.1 |

3モデルとも日本語翻訳は正常 (chrF 49-91、破綻なし)。英->日がやや低いのは参照訳 1本の
小サンプルによる chrF 特性で、実出力は自然な日本語だった。gpt-oss-20b が日->英で突出。

> 落とし穴メモ: Qwen3 系を thinking 有効のまま翻訳させると `<think>...` が訳文前に大量出力され
> chrF が崩れる (Qwen3-14B で 26.5/5.1 に激減)。thinking 無効化で 71.1/49.1 に回復。要約/翻訳
> バッチでは reasoning を切るのが必須。

---

## 計測サマリ 4: 要約品質 (参考値, LLM-as-judge = Claude Opus 4.8, 中央値)

日本語記事 5本を各モデルに要約させ (3文以内)、**Claude Opus 4.8 (Bedrock)** で 4観点を
1-5 採点。各要約を **3回 judge して中央値**、さらに記事間で中央値を取る。Qwen3 系は
thinking 無効化。

| モデル | 要点網羅 | 忠実性 | 日本語の自然さ | 簡潔性 | 総合 |
|---|---|---|---|---|---|
| gpt-oss-20b | 5 | 5 | 5 | 5 | **5.0** |
| Qwen3-30B-A3B-Instruct-2507 (FP8) | 5 | 5 | 5 | 5 | **5.0** |
| Qwen3-14B | 5 | 5 | 5 | 5 | **5.0** |

3モデルとも全観点満点。日本語要約は要点網羅・忠実性 (幻覚なし)・自然さ・簡潔性のすべてで高品質で、
「壊れている/ひどい」ものは無い。ミニ評価 (易しめ 5記事) のため満点続出で、モデル間の細かな優劣は
分離できない (それには難しめ・長文・多数記事が必要)。目的の sanity check は達成。judge の
`temperature` は Opus 4.8 で非対応のため未指定 (deterministic 寄り) で実行した。

---

## 損益分岐: 自前 vs API

### 要約 (100万件・入力45+出力100 tok = 総145M tok の例)

| 方式 | コスト | 処理時間 (L40S 1枚) |
|---|---|---|
| **自前 g6e: gpt-oss-20b** | **$3.99** | 約 2.2h |
| 自前 g6e: Qwen3-30B-A3B | $7.74 | 約 2.2h |
| API: Amazon Nova Lite (batch 50%off) | $13.35 | 即時 |
| API: gpt-oss-20b (Bedrock, batch) | $16.57 | 即時 |
| API: Claude Haiku 4.5 (batch) | $272.50 | 即時 |
| API: GPT-5.4 (Bedrock, batch) | $886.88 | 即時 |

→ **コスト最小は自前 gpt-oss-20b**。ただし g6e 起動〜片付けの手間を考えると、
少量・単発なら **Nova Lite batch ($13)** が現実的。品質重視の Haiku/GPT-5.4 はこの規模では割高。
規模が 10x/100x になるほど自前の優位が線形に拡大する。

### embedding (100万文書・512入力tok = 512M tok の例)

| 方式 | コスト | 処理時間 |
|---|---|---|
| **自前 Graviton: ruri-v3-30m (int8)** | **$3.37** | 約 2.6h |
| API: Titan Text Embeddings V2 (batch) | $5.12 | 即時 |
| 自前 Graviton: ruri-v3-130m | $12.22 | 約 9.6h |
| API: Titan V2 / OpenAI 3-small | $10.24 | 即時 |
| **自前 Graviton: ruri-v3-310m (JA最高精度)** | $25.69 | 約 20h |
| API: Cohere Multilingual v3 (Bedrock) | $51.20 | 即時 |
| API: OpenAI text-embedding-3-large | $66.56 | 即時 |

→ **軽量モデルなら自前が最安** (ruri-30m $3.4 < Titan V2 batch $5.1)。
一方 **日本語最高精度の ruri-v3-310m を使うなら自前でも $25.7** で、API に日本語で
これを超えるものが少ないため「精度が要るなら自前一択・ただし高い」という分岐になる。
手間なし中庸は Titan V2 batch / OpenAI 3-small ($5-10)。

---

## 再現の要点

- **要約**: g6e (DLAMI PyTorch 2.7) に `pip install vllm` (0.24.0)。
  `scripts/summarization_throughput.sh <GPU> <tag> <hf_repo>` が入力x出力 sweep を実行。
  入力トークンは `--dataset-name random --random-range-ratio 0` で厳密統制。
  MoE の FP8 モデルは L40S (Ada) で FP8 が効く (A100=Ampere は非対応な点に注意、別記録参照)。
- **embedding**: Graviton (Ubuntu 24.04 arm64) に `pip install onnxruntime transformers huggingface_hub`。
  `scripts/embedding_throughput.py` が model x quant x input_len x batch を sweep (3回中央値)。
  ruri は prefix ("検索文書: " / "検索クエリ: ") 必須。int8 ONNX はコミュニティ変換 (sirasagi62/*) を使用。
  EmbeddingGemma は ONNX external-data のパス検証を避けるため flat-dir へコピーして load
  (`embedding_throughput_gemma.py`)。
- **API 価格** (2026-07 一次確認, 概算): Nova Lite $0.06/$0.24, gpt-oss-20b(Bedrock) $0.07/$0.30,
  Claude Haiku 4.5 $1/$5, GPT-5.4(Bedrock) $2.75/$16.50, Titan Embeddings V2 $0.02 (batch $0.01),
  OpenAI text-embedding-3-small $0.02 / -large $0.13。Bedrock batch は 50% 引き (対象モデルのみ)。

> 注: 価格・スループットは計測時点の概算。契約前に各社公式ページ / 自環境実測での再確認を推奨。
> スループット絶対値は使用モデル・入力長分布・vLLM/ORT バージョンで変わる。
