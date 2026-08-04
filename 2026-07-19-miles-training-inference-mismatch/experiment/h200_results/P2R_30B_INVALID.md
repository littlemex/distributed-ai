# 30B MoE の mismatch 計測は現行設定では成立しない (2026-08-03)

> **データ裏付け: UNUSABLE (実在するが測定として無効)** — 本ファイルの数値は run `p2r_30b_bf16` / `p2t_30b_bf16_16k` / `p2x_30b_t06` / `p2w_30b_wcheck` の TensorBoard event file に
> 由来する。判定と引用可否の定義は同ディレクトリの `DATA_STATUS.md`、照合コマンドは
> `python3 verify_results.py` (Ray head pod)。数値を他の文書へ転記する前に必ず照合する。


30B MoE の 3 セルを再取得しようとして bf16 セルを完走させたが、その値は
mismatch の指標として使えない。原因を特定したので記録する。残り 2 セルは投入を中止した
(壊れた baseline の上に fp8 を乗せても解釈できないため)。

## 観測された値と、それが異常である根拠

`p2r_30b_bf16` (job `raysubmit_icrN98yq5nuiKpPT`, TensorBoard で確認済み):

| メトリクス | 30B MoE | 8B dense (同日・同ドライバ) | 判定 |
|---|---|---|---|
| `train/mis_kl` | **0.309076** | 0.000745 | dense の **415 倍** |
| `train/mis_chi2_token` | **54.69** | 0.001433 | 桁が違う |
| `train/mis_training_ppl` | **2.806** | 1.412 | |
| `train/mis_rollout_ppl` | **1.697** | 1.411 | |
| `train/mis_ppl_ratio` | **1.781** | **1.00075** | 決定的 |
| `rollout/raw_reward` | **0.0** | 0.453 | 決定的 |

`mis_ppl_ratio` が 1.78 ということは、trainer と rollout engine が **78% も違う
perplexity** を出しているという意味である。数値経路差 (bf16 で 0.07% 程度) では
説明できない大きさで、両者が実質的に異なる分布を評価している。

## 根本原因: 応答が打ち切られていて報酬が構造的にゼロになる

| run | `rollout/truncated` | `response_lengths` | `raw_reward` |
|---|---|---|---|
| 30B MoE (p2r_30b_bf16) | **0.992** | 8131 / 8192 | **0.0** |
| 30B MoE (h200_smoke_30b, 08-02) | **0.961** | 7907 / 8192 | **0.0** |
| 8B dense (p2m_8b_bf16) | 0.547 | 6958 | 0.453 |
| 4B dense (h200_smoke_plain) | 0.500 | 6600 | 0.477 |

**30B は 99% の応答が `--rollout-max-response-len 8192` で打ち切られている。**
Qwen3-30B-A3B は thinking モデルで、DAPO-Math の問題に対する推論が 8192 トークンでは
終わらない。答えに到達しないので `deepscaler` reward は常に 0 になる。

これは mismatch 計測にも波及する。打ち切られた応答は末尾が推論の途中であり、
trainer 側と rollout 側で長さや扱いが揃わない領域が支配的になる。
`mis_chi2_token` 54.7 という値は、裾のごく一部のトークンが極端な比を持つことを示しており、
「量子化による誤差」ではなく「打ち切りに起因する不整合」を測っている。

## これは以前の報告の訂正を含む

前セッションで `h200_smoke_30b` を「SUCCEEDED、30B MoE colocated 16 GPU 構成が動くことを
確認」と報告した。ジョブが SUCCEEDED で終わったのは事実だが、**その run も reward 0.0 /
truncated 0.96 だった**。つまり確認できていたのは

- 30B が 16 GPU に載り、EP2 の all-to-all を含めて**クラッシュせず完走する**

までであって、

- 30B が**意味のある学習・推論をしている**

ことは確認できていなかった。「動く」という言葉でこの 2 つを区別していなかったのは
私の報告の誤りである。upstream README の
`Qwen3-30B-A3B MoE GRPO, colocated, 2 nodes (16 GPU) | Verified` という行も、
この区別を反映して書き直す必要がある (インフラ構成としては verified、
学習品質は未検証)。

## 追加検証 1: 長さ上限を倍にしても打ち切り率は変わらない

`--rollout-max-response-len` を 8192 -> 16384 に上げた probe (`p2t_30b_bf16_16k`,
job `raysubmit_hPttUSbFWW8tNma5`):

| | 8192 上限 | **16384 上限** |
|---|---|---|
| `rollout/truncated` | 0.9922 | **0.9922 (変化なし)** |
| `response_lengths` | 8131 / 8192 | **16327 / 16384** |
| `raw_reward` | 0.0 | **0.0** |
| `mis_ppl_ratio` | 1.781 | 1.319 |
| `mis_kl` | 0.309 | 0.196 |

**打ち切り率が 1 桁も動かず、与えた上限をそのまま埋め尽くしている。**
これは「推論が長いので 8192 では足りない」ではなく、**生成が停止しない (degenerate)**
ことを意味する。長さを増やす方向の対策では解決しない。

## 追加検証 2: dense 側は健全である (この問題は MoE 固有)

同じドライバ・同じ日・同じクラスタで取った全セルを並べる:

| run | mis_kl | ppl_ratio | reward | truncated |
|---|---|---|---|---|
| h200_p4_calib (4B bf16) | 0.000627 | 1.00063 | 0.555 | 0.430 |
| e4_c2_kv_e4m3 (4B) | 0.008654 | 1.00869 | 0.484 | 0.516 |
| e4_c1_kv_e5m2 (4B) | 0.032439 | 1.03300 | 0.461 | 0.523 |
| p2m_8b_bf16 | 0.000745 | 1.00075 | 0.453 | 0.547 |
| p2m_8b_e4m3 | 0.007755 | 1.00779 | 0.422 | 0.578 |
| p2m_8b_e5m2 | 0.025758 | 1.02611 | 0.422 | 0.578 |
| **p2r_30b_bf16** | **0.309076** | **1.78129** | **0** | **0.992** |
| **p2t_30b_bf16_16k** | **0.196407** | **1.31854** | **0** | **0.992** |

dense 6 セルは `ppl_ratio` が 1.033 以下、reward 0.42-0.55、打ち切り 0.43-0.58 で
一貫している。**異常なのは 30B の 2 セルだけ**であり、
`P2M_MODEL_SCALE.md` の 4B/8B の結論は影響を受けない。

## 追加検証 3: 真の原因は反復ループ (repetition) である

`rollout/repetition_frac` を全 run で比較すると原因が一意に決まる:

| run | `repetition_frac` | `truncated` | reward |
|---|---|---|---|
| 8B dense (p2m_8b_bf16) | **0.0** | 0.547 | 0.453 |
| 4B dense (smoke/dump1) | **0.0** | 0.477 | 0.523 |
| 30B MoE (8192 上限) | **0.633** | 0.992 | 0.0 |
| 30B MoE (16384 上限) | **0.695** | 0.992 | 0.0 |

**dense は反復ゼロ、30B は 63-70% の応答が反復ループに入っている。**
eval 側はさらに酷く `eval/aime/repetition_frac: 0.85`。

これで観測されたすべてが説明できる。反復ループに入る -> 停止しない -> 上限まで生成して
打ち切られる (上限を倍にしても同じ率で打ち切られる) -> 答えに到達しない -> reward 0。
そして反復するトークン列では trainer と rollout の logprob が大きくずれるため
`mis_ppl_ratio` が 1.3-1.8、`mis_chi2_token` が 54-74 になる。
つまり **30B の mis_kl は「量子化の誤差」でも「MoE の router フリップ」でもなく、
「反復ループの副産物」を測っていた**。

なお `--check-weight-update-equal` を有効にした run では `update_weights` が
`ok=true elapsed_s=7.2` で通り、アサーションは発火しなかった。また
`rollout/weight_version` は全サンプル 1.0 で `mixed_version_ratio: 0.0`。
**trainer と engine の重みは一致している**ので、weight sync の不具合ではない。

反復の原因として最初に疑ったのは `--rollout-temperature 1.0` が Qwen3-30B-A3B の
推奨値 (generation_config は temperature 0.6 / top_p 0.95 / top_k 20) から外れていること
だったが、これは追加検証 4 で否定された。

## 30B で mismatch を測るなら必要なこと

反復を止めないと何を測っても交絡する。検証済み・未検証を分けて記す。

| 対策 | 状態 |
|---|---|
| 長さ上限を 16384 に上げる | **検証済み・効果なし** (打ち切り率 0.992 で不変) |
| weight sync の不具合を疑う | **検証済み・否定** (`check-weight-update-equal` 通過、weight_version 一致) |
| `--rollout-temperature` を 0.6 に下げる (モデル推奨値) | **検証済み・効果なし** (下記) |
| top_p 0.95 / top_k 20 を明示指定する | 未検証 |
| repetition penalty を入れる | 未検証。ただし 4B/8B と条件が変わる |

## 追加検証 4: 温度も原因ではない

`--rollout-temperature` を 1.0 -> 0.6 (Qwen3-30B-A3B の generation_config 推奨値) に
下げた run (`p2x_30b_t06`, job `raysubmit_6qeh5DVpXF85n8Wc`)。
`rollout_temperature ... 0.6` がログに出ており、設定は確実に engine に届いている。

| run | 温度 | `repetition_frac` | `truncated` | `mis_ppl_ratio` |
|---|---|---|---|---|
| 30b_bf16 | 1.0 | 0.6328 | 0.992 | 1.78 |
| 30b_bf16_16k | 1.0 | 0.6953 | 0.992 | 1.32 |
| **30b_t06** | **0.6** | **0.6328 (不変)** | 0.969 | **1.7e+11** |

**反復率は 0.6328 でまったく動かなかった** (温度 1.0 の値と小数第 4 位まで同一)。
サンプリング温度は原因ではない。

さらに温度 0.6 の run では `mis_ppl_ratio` が 1.7e+11 という無意味な値になった。
これは logprob の差が exp で発散していることを意味し、指標そのものが
この条件下では計算として崩れていることを示す。`mis_kl` 0.839 も同様に解釈不能である。

## 現時点の結論: 原因は未特定。30B は保留する

4 つの仮説をすべて実測で否定した。

| 仮説 | 検証方法 | 結果 |
|---|---|---|
| 応答長の上限不足 | 8192 -> 16384 | 否定 (打ち切り率 0.992 不変) |
| trainer/engine の重み不一致 | `--check-weight-update-equal` | 否定 (通過、weight_version 一致) |
| サンプリング温度が高すぎる | 1.0 -> 0.6 | 否定 (反復率 0.6328 不変) |
| モデルファイルの破損 | config/generation_config を 8B と比較 | 否定 (eos/vocab 一致、conversion サイズ正常) |

残る候補は、この repo の 30B 経路 (MoE の weight 変換、`triton` MoE runner backend、
EP2 の expert 配置など) が生成品質を壊しているというもので、切り分けには
「SGLang 単体で HF checkpoint を直接サーブして反復するか」を見る必要がある。
それは miles の GRPO 経路の外にある検証で、CB の残り時間で本題より優先する価値はない。

したがって **30B は「インフラは完走するが生成品質が壊れており、mismatch 計測には
使えない」として保留する**。upstream README の記述もこの区別を反映させる。

モデル規模軸としては 30B を諦め、4B/8B の 2 点 (どちらも dense・同一条件) で結論を述べる。
30B は「この repo の MoE 経路で生成が反復に陥る」という別の知見として切り出す。
これ自体は報告価値がある (同じ温度・同じデータで dense は反復ゼロ、MoE は 63%) が、
原因の特定には miles の GRPO 経路の外での切り分けが必要で、本題より優先しない。

## モデル規模軸への影響

3 点目 (30B) は現状使えないので、モデル規模軸は **4B と 8B の 2 点のまま**である。
`P2M_MODEL_SCALE.md` の結論 (倍率はモデル依存、移植可能なのはオーダーのみ) は
2 点に基づくもので、3 点目が入っていないという限界が残る。

なお 30B が dense ではなく MoE であることも、規模軸の 3 点目としては本来交絡している
(パラメータ数と MoE/dense が同時に変わる)。8B を入れたのは 4B と同じ dense で
パラメータ数だけを変えるためだった。その目的は達成できている。

## 決着 (2026-08-04): 原因は expert parallelism (EP) だった

上の「現時点の結論」で次の一手として書いた「SGLang 単体で HF checkpoint を直接サーブして
反復するか」を実施した。**再現した。そして原因を EP に特定した。**

詳細は `../moe_probe/README.md`。要点だけ:

| cell | TP | EP | backend | sampling | `repetition_frac` |
|---|---|---|---|---|---|
| `A_repro` (miles と同一構成) | 4 | 2 | triton | miles 既定 | **0.875** |
| `D_sampling` | 4 | 2 | triton | **Qwen 推奨** | 0.875 |
| `C_backend` | 4 | 2 | **既定** | miles 既定 | 0.844 |
| `B_tp1` | 1 | 1 | triton | miles 既定 | 0.000 |
| **`F_tp4_ep1`** | **4** | **1** | triton | miles 既定 | **0.000** |
| **`F_tp4_ep1`** | **4** | **1** | triton | miles 既定 | **0.000** |
| `H_tp8_ep1` | 8 | 1 | triton | miles 既定 | 0.000 |
| `I_tp8_ep2` | 8 | 2 | triton | miles 既定 | 0.594 |
| `J_tp8_ep4` | 8 | 4 | triton | miles 既定 | 0.844 |
| `E_dense` (8B dense) | 4 | 1 | 既定 | miles 既定 | 0.000 |

- **miles の GRPO ループを一切通さずに再現した** (0.875 は実測 0.633 より高い)。
  したがって GRPO・weight sync・Megatron 側はすべて無関係で、4 つの仮説が空振りした理由も
  これで説明がつく (すべて miles 内部を疑っていた)。
- **原因は EP (expert parallelism) である。** EP=1 の 3 セル (TP 1/4/8) はすべて 0.000、
  EP>1 の 5 セル (TP 4/8) はすべて 0.594 以上。TP は完全に無関係だった。
- **EP を増やすほど悪化する。** TP=8 固定で EP だけを振ると
  EP1 -> 0.000、EP2 -> 0.594、EP4 -> 0.844。偶発ではなく用量反応である。
- サンプリングは原因でない。Qwen 公式推奨値 (temp 0.6 / top_p 0.95 / top_k 20) でも 0.875。
  これは Web 調査で最有力だった仮説の棄却である。
- `moe_runner_backend` の明示指定も原因でない。既定 (auto) に戻しても 0.844。

**この節より下の Web 調査 (仮説の整理) は、実測の前に書いたものである。** 仮説 A
(TP/EP シャーディング形状と kernel の不整合) は方向として当たっていたが、
具体的な機構 (ROCm/aiter のフォールバック) はこの環境では発火しないので別物である。
記録として残す。

## Web 調査 (2026-08-04): 仮説の整理 (実機検証はしていない)

上の「現時点の結論」で次の一手として書いた「SGLang 単体で HF checkpoint を直接サーブして
反復するか」の検証はまだ実施していないが、その前段としてクラスタ外で web 調査を行った。
2 系統のエージェントに分けて調査し、以下は見つかった一次情報の要約である。
**いずれも実機で再検証していない仮説であり、この節の内容は `UNUSABLE` 判定を動かさない。**

### 見つかった一次情報のうち、この症状と一致度が高いもの

| ソース | 内容 | この症状との一致 |
|---|---|---|
| QwenLM/Qwen3 issue #1384 | Qwen3-30B-A3B は vLLM 上で反復無限ループに陥りやすいと開発者(jklj077)自身が認めており、`presence_penalty=1.5` を回避策として推奨 | モデル自体の既知の弱点。ただし単独では repetition_frac 0.48-0.70 という大きさや mis_ppl_ratio 1.3-1.8 は説明しきれない |
| SGLang PR #28244 | **Qwen3-30B-A3B 特有**。TP=8 で `intermediate_size/TP=96` が aiter CK kernel の要求形状(128 の倍数)を満たさず triton へ暗黙フォールバックするが、重みは CK 用レイアウトに shuffle済みのままのため triton が誤ったレイアウトを読み、garbled/repetitive 出力になる | **最も一致度が高い**。「明示的に `--sglang-moe-runner-backend triton` を指定する必要があった」という今回の経緯そのものが、同種の backend 切替パスの脆弱性を疑わせる |
| vLLM PR #48032 | Marlin MoE の `moe_align_block_size` がトークン整列順序を非決定にし、量子化 GEMM でその順序差が top-1/top-2 境界のルーティングを反転させ、実機で "reasoning loop" が再現・特定された | 「反復ループ」の発生機序としては具体的で一致度が高いが、量子化(Marlin)経路の話で今回の bf16 ロードには直接は当てはまらない可能性 |
| vLLM issue #30321 / PR #45683 | Qwen3-30B-A3B-Instruct-2507 を DP+EP で動かすと `VLLM_BATCH_INVARIANT=1` でも DP>2 でサンプルトークンが変わる。MoE combine の reduce 順序が EP のトークン分配に依存して変わることが根本原因と明記 | MoE 特有の並列化構成依存の非決定性を示す直接証拠。ただし「反復」そのものより「再現性」の問題 |
| NVIDIA/Megatron-LM issue #5844 / PR #5845 | HF→Mcore の checkpoint 変換で MoE expert 重みが無警告で未初期化のまま保存される既知バグ (Mixtral) | 一致度は当初高いと思ったが、**要注意**: `rollout/repetition_frac` は SGLang (rollout) が生成した出力を測っており、Megatron 変換後の重みではなく生成直後の HF checkpoint そのものに対する SGLang の生成結果に依存する。したがって今回の症状 (optimizer step 前・rollout 側で既に反復) を Megatron 変換バグだけで説明するのは無理がある可能性が高い |

### 見つからなかったもの

- SGLang 本体側で今回名前が挙がった issue #2091 / #1840 に相当する反復崩壊 issue は見つからなかった (THUDM/slime 側の別issueが近いのみ)。
- router (gating) 自体の量子化精度が top-k 選択を反転させるという直接の論文・実測報告は見つからなかった。
- 「MoE は構造的に repetition を起こしやすい」と理論的に論じた論文は見つからなかった (ST-MoE の router z-loss は訓練時の routing collapse の話で、推論時の自己強化的反復ループの理論的説明ではない)。
- 「training-inference mismatch は MoE の方が dense より大きい」と明言した論文・ブログも見つからなかった (間接証拠のみ)。

### 整理: 最も有力な仮説 (未検証)

`rollout/repetition_frac` が測っているのは **SGLang が HF checkpoint を読んで生成した結果**であり、
これは Megatron 側の訓練パスを経由していない。したがって Megatron のチェックポイント変換バグ
(issue #5844 系) は今回の第一原因としては説明力が弱く、**SGLang の MoE 推論パス自体
(triton runner backend への切替、または Qwen3-30B-A3B が公式に認めている反復しやすい体質)**
の方が時系列と一致する。

次の一手 (このドキュメントの「現時点の結論」に既に書いてあったが未実施) は変わらず:
**SGLang 単体・miles の外で、同じ HF checkpoint を同じ temperature/max_tokens で serve し、
反復が再現するかを見ること。** 再現すれば SGLang/rollout 側の推論バグに絞れる。
再現しなければ miles 側の prompt 処理や chat template 適用に疑いが移る。
