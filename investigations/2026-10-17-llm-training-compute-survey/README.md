# LLM の学習の計算量とデータ量の公開値の集計

公開された技術報告、論文、公式の model card から、LLM の事前学習のトークン数、GPU 時間、post-training の GPU 時間、RL の rollout が時間に占める割合を集め、統計とグラフにしたもの。Zenn の記事「post-training 時代の LLM 学習の規模と効率の整理」の数値とグラフは、すべてこのディレクトリのデータとスクリプトから再現できる。

## ディレクトリ

```
2026-10-17-llm-training-compute-survey/
├── data/
│   ├── models.csv          一次資料から集めたモデルごとの値
│   ├── llm_extra.csv       一次資料で足したモデルと、Epoch AI のデータベースの言語モデル
│   ├── rollout_share.csv   RL の 1 回の反復で rollout が時間に占める割合
│   ├── bench_joined.csv    ベースモデルのベンチマークの点数と、active パラメータ、トークン数
│   ├── bench_joined_fixes.csv  bench_joined.csv の値のうち一次資料と食い違うものの訂正
│   ├── bench_model_family_year.csv  ベースモデルの系列 (lineage) と公開年
│   ├── aa_intelligence_index.csv  Artificial Analysis の Intelligence Index (2026-10-17 取得)
│   └── aa_mapping_audited.csv  Intelligence Index の版と、事前学習の対応
├── verify/
│   └── part1〜3_result.csv グラフに描いた点の抜き取り検査の結果
├── scripts/
│   ├── build_charts.py     グラフ 6 枚を figures/ に書き出す
│   ├── benchmarks.py       ベースモデルの点数の回帰と、その係数のグラフ
│   ├── summarize.py        記事のまとめに使った統計を出力する
│   └── estimates.py        記事の単純なモデルによる試算を出力する
└── figures/                build_charts.py の出力
```

## 再現の手順

Python 3.10 以降と [uv](https://docs.astral.sh/uv/) を使う。

```bash
git clone https://github.com/littlemex/distributed-ai.git
cd distributed-ai/investigations/2026-10-17-llm-training-compute-survey
uv run --with matplotlib python scripts/build_charts.py
uv run --with matplotlib python scripts/summarize.py
uv run --with numpy --with matplotlib python scripts/benchmarks.py
python3 scripts/estimates.py
```

`build_charts.py` は `figures/` に次の 6 枚を書き出し、`benchmarks.py` は 7 枚目を書き出す。

| ファイル | 中身 |
|---|---|
| `params-vs-tokens.png` | 総パラメータ数と事前学習のトークン数 |
| `tokens-per-param-by-date.png` | リリースの年と active パラメータあたりのトークン数 |
| `compute-vs-gpu-hours.png` | $6 N_\text{active} D$ と報告された GPU 時間 (H100、H800、H200) |
| `rl-gpu-hours.png` | RL の post-training の GPU 時間 |
| `rollout-share.png` | RL の反復で rollout が時間に占める割合 |
| `moe-active-share-by-year.png` | MoE のモデルの active パラメータの割合とリリースの年 |
| `tpp-effect-at-fixed-compute.png` | 計算量をそろえたとき、active パラメータあたりのトークン数が 10 倍違うベースモデルの点数の差 |

## データの定義

`models.csv` の主な列は次のとおり。値の無い列は空欄で、推測で埋めていない。

| 列 | 意味 |
|---|---|
| `total_b`、`active_b` | 総パラメータと、1 トークンの計算に使うパラメータ (十億) |
| `pretrain_tokens_t` | 事前学習のトークン数 (兆)。継続事前学習と post-training のトークンは含めない |
| `pretrain_gpu_hours_m` | 事前学習の GPU 時間 (百万) |
| `pretrain_gpu_hours_kind` | `reported` は報告値、`computed` は報告された枚数と期間からの計算値 |
| `rl_gpu_hours_k`、`rl_gpu_hours_kind` | RL の GPU 時間 (千) と、報告値か、確保の枚数と期間からの計算値か |
| `source_urls` | 値の出典 |

`llm_extra.csv` の `source_kind` が `epoch` の行は、[Epoch AI](https://epoch.ai/data) の Large-Scale AI Models のデータ (CC BY 4.0) から言語モデルを抜き出したもので、グラフでは一次資料の点と描き分けている。一次資料と Epoch AI の値が食い違う行は、一次資料の値を採り、`notes` に両方を残した。

グラフでは、継続事前学習やファインチューニングだけのモデル、視覚と音声のモデル、総パラメータが 1B 未満か学習トークンが 0.05T 未満の Epoch AI の行を除いている。MoE と状態空間のモデルを組み合わせた `hybrid` は、active パラメータが総パラメータの 9 割未満なら MoE に数える。

`bench_joined.csv` は、[Ruan ら](https://arxiv.org/abs/2405.10938)が Open LLM Leaderboard と同じ評価の手順にそろえて集めたベースモデルの点数 ([ObsScaling](https://github.com/ryoungj/ObsScaling))、Hugging Face の Open LLM Leaderboard の v1 と v2、[Epoch AI の Benchmarking Hub](https://epoch.ai/data) の値を、`models.csv` と `llm_extra.csv` のパラメータ数とトークン数につないだ長い形式の表で、`source` 列に出典を残している。`benchmarks.py` が回帰に使うのは、Ruan らの値で 25 モデル以上がそろうベンチマークだけである。`aa_mapping_audited.csv` の `same_pretrain_weights` は、技術報告と model card で事前学習が同じだと確かめられた版を `yes` とし、継続事前学習を足した版を `no`、確かめられなかった版を `unknown` とする。

## 抜き取り検査

グラフに描いた 59 モデル、297 項目を一次資料と突き合わせ、誤り 4 件を直した。結果は `verify/` にある。確認できなかった値は 2 種類ある。

- 一次資料が下限だけを書いているもの。Llama 3.1 と Llama 3.3 の 15T は公式の「15T+」の下限。
- 合計が書かれておらず、枚数と期間からの計算値のもの。Nemotron-4 340B と Reflection AI の Beam の GPU 時間。

## 限界

- 公開値は組織ごとに数え方が違う。GPU 時間には学習に使った時間と、実験を含めてクラスタを確保していた時間が混ざる。
- `compute-vs-gpu-hours.png` の比は $6 N_\text{active} D$ だけを数え、attention の計算量と中断を含まないので、MFU そのものではない。
- `benchmarks.py` の 95 % の区間は、`bench_model_family_year.csv` の `lineage` (継続事前学習や蒸留の元、同じ学習データを共有するモデルの集まり) を単位に再抽出するパーセンタイルのブートストラップで求め、p 値は再抽出した係数が 0 の反対側に出た割合から求める。公開年は同じ表に月の精度で置き、`release year added` の回帰はこの公開年を説明変数に加える。表にないモデルや同じモデルの重複があると、スクリプトは止まる。
- `estimates.py` の値は、記事で置いた仮定 (step 時間の内訳、$\eta = 0.95$、HBM の 90 % を使えるなど) による試算で、実測ではない。
