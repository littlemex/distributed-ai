# データ台帳: どの数値が裏付けを持つか

**この表が正本である。** ブログ・登壇資料・upstream PR に数値を書くときは、
必ずこの表で verdict を確認してから引用する。表に無い数値、または `MISSING` の
セルの数値は、どこに書かれていても裏付けが無い。

生成コマンド (Ray head pod 上、`/fsx` がマウントされた環境で実行):

```bash
cd /tmp/miles-run && python3 verify_results.py --json /fsx/exp/VERIFICATION.json
```

実装: `/Users/akazawt/tmp/distai-p5-ue2-miles/verify_results.py`
最終実行: 2026-08-03

## 2026-08-04 の監査で塞いだ穴 (再発防止テスト付き)

Fable と独立レビューで **ハーネス自身**を攻撃し、「間違った数値が文書に到達しうる経路」を
探した。以下は実際に開いていた穴で、すべて `test_harness.py` の回帰テストで塞いだ
(33 チェック、ローカルとクラスタ両方で全 PASS)。

| 穴 | 何が起きえたか | 検証 |
|---|---|---|
| `agree(inf, inf)` が True | 発散した run の `grad_norm=inf` が **VERIFIED** の判子付きで表に載る | `inf` を `NONFINITE` verdict に分離 |
| sanity screen の tag 欠損が pass | 3 つの screen を **1 つも記録していない run** が「screen 通過」と報告される (30B 事故の再来) | `UNSCREENED` verdict を新設。screen 0 件は pass でなく「未検査」 |
| screen 値が NaN で pass | `nan > 0.05` も `nan <= 0.0` も False なので **NaN は全 screen を通過** | NaN も `UNSCREENED` に倒す |
| overall verdict の集約 | reward だけ VERIFIED で `mis_kl` が MISSING の cell が **緑の VERIFIED** で通る | core metric (`mis_kl`/`reward`) が未検証なら `PARTIAL` に降格 |
| tb run の曖昧一致 | `e4m3_s123` が `pp3_*` と `8bs_*` の両方に一致し `hits[0]` で**別 run の event file と照合** | 曖昧なら `AMBIGUOUS_PAIRING` で fatal。実データでは 0 件 |
| driver row 無しの run | step 0 を書いた直後に kill された job も引用可能判定 | `TB_ONLY_UNCONFIRMED` に分離 |
| dump の run-id 正規表現 | 数字/小文字hex 以外の run id (`raysubmit_*`, 大文字hex, 任意ラベル) が**照合を素通り**し 2 run 混在が検知されない | prefix 全体で group。mis_dump 形式でないファイルは fatal |
| NaN → 「flat」判定 | `-inf`/NaN が 1 つあると bootstrap CI が NaN になり、`lo>0`/`hi<0` 両方 False で **「蓄積なし」という確定的な陰性結論**になる | 非有限トークンを除外・計数し、CI が非有限なら `UNDECIDED` |
| `t_crit()` の補間方向 | 表に無い df で**真値より小さい**臨界値を返し CI が狭まる (df=11 は 2.179 対 真値 2.201、df≥31 は 1.96 対 2.040)。有意性を捏造する方向 | 切り下げ (保守側) に修正。16 df で検算 |
| `MIS_DUMP_EVERY` 既定 4 | call 数 4 未満の run が**無警告でゼロ dump**。「データが無い」と「dump しなかった」が区別不能 | 既定 1 に変更 |
| 凍結 base env が未使用 | `gen_cells.py` は base env を凍結コピーするのに、cell は **/tmp の原本を source** していた。凍結ハッシュは誰も読まないファイルの記録 | cell は凍結コピーを source。base が読めなければ生成自体を拒否 |

**重要: 上記の修正後、公開済みの数値はすべて再現した。** 実機で再実行し、
台帳の VERIFIED 6 セル、位置プロファイル (`sm_dump1` slope -3.212623e-07、alpha_within 1.03)、
4 seed プール (bf16 平均 -3.247e-07 / SE 3.549e-08 / 区間 [-4.376e-07, -2.117e-07]) が
すべて一致。verdict も 1 件も変わっていない。つまりこれらは**潜在的な穴**であって、
既発表の結論を動かすものではなかった。実データでの実測: 非有限トークン 0 件、
重複 0 件 (全 14 dump ディレクトリ)、曖昧 pairing 0 件。

## 判定の意味

| verdict | 意味 | 引用可否 |
|---|---|---|
| `VERIFIED` | TensorBoard event file と driver の `results.tsv` の**両方**にあり、値が一致 | **可** |
| `TB_ONLY` | trainer が書いた event file にのみ存在 (driver 導入前の run) | **可** (単一ソース) |
| `DRIVER_ONLY` | `results.tsv` にあるが event file に無い | **不可** (要調査) |
| `DISAGREE` | 両方にあるが値が違う | **不可** |
| `MISSING` | どちらにも無い。**文書に数値があればそれは捏造** | **不可** |
| `NOT_SUCCEEDED` | run は存在するが terminal status が SUCCEEDED でない | **不可** |
| `*_BUT_UNUSABLE` | 数値は本物だが、step 0 の健全性スクリーンに落ちている | **測定値としては不可** |

`VERIFIED` は「異なるコードパスが書いた 2 つのソースが一致した」ことを意味する。
捏造事故は「どのソースにも無い数値が文書にだけ存在した」ものなので、
この二重確認が再発防止の要になる。

## 健全性スクリーン (step 0 で判定)

値が本物でも意味が無いことがある。30B MoE は実在する run から `mis_kl` 0.309 を出したが、
生成が反復ループに入っていた。そこで以下を **step 0 で** 判定する。

| 指標 | 閾値 | 落ちた場合の意味 |
|---|---|---|
| `rollout/repetition_frac` | <= 0.05 | 生成が反復している。logprob 差は反復を測っている |
| `train/mis_ppl_ratio` | <= 1.5 | trainer と rollout が実質的に別の分布を評価している |
| `rollout/raw_reward` | > 0.0 | 正答がゼロ。応答が答えに到達していない |

**step 0 で判定するのが要点である。** collapse/TIS の run は「悪化すること」が結果なので、
最終 step で判定すると発見そのものを不良品と判定してしまう。実際 `amplified_*` は
step 0 で repetition 0 / reward 0.40-0.50 から始まり、30 step かけて
repetition 0.27 / reward 0.03 まで歩く。一方 30B は **optimizer step を 1 回も踏む前から**
反復しているので、訓練力学とは無関係に壊れている。この 2 つは種類が違う。

## 現在の判定結果

### 引用可能 (VERIFIED = 二重確認済み)

| cell | mis_kl | 用途 |
|---|---|---|
| `8b_bf16` | 0.000745082 | モデル規模軸 |
| `8b_e4m3` | 0.0077553 | モデル規模軸 |
| `8b_e5m2` | 0.0257582 | モデル規模軸 |
| `dump1` | 0.000624546 | 位置プロファイル bf16 対照群 |
| `e4m3` (`pp_e4m3`) | 0.00935957 | 位置プロファイル fp8_e4m3 |
| `e5m2` (`pp_e5m2`) | 0.0329066 | 位置プロファイル fp8_e5m2 |
| `e5m2_collapse_train` (batch `ptc_collapse2`) | 31.777252 | **崩壊領域**の位置プロファイル (30 step 完走、dump 1424) |

位置プロファイルの 3 arm は per-token ダンプも保持している
(`/fsx/dumps/{sm_dump1,pp_e4m3,pp_e5m2}/`、各 120 ファイル)。
解析結果は `PP_POSITION_PROFILE.md`。

### 引用可能 (TB_ONLY = 単一ソースだが trainer の一次データ)

| 群 | cells | 用途 |
|---|---|---|
| P1 並列不変性 | `h200_p1_tp2/tp4/tp8/tp16/tp4cp2/tp8pp2` | 並列構成の影響 |
| P3 weight sync | `h200_p3_colo_tp1/tp2/tp4/tp8` | 手法差 |
| P4 キャリブレーション | `h200_p4_calib` | H100/H200 差、4B bf16 |
| E4 KV スイープ | `e4_c0_auto`, `e4_c1_kv_e5m2`, `e4_c2_kv_e4m3`, `e4_c3_kv5_triton`, `e4_c4_nocudagraph`, `e4_c5_triton_only` | 4B の量子化 |
| collapse / TIS | `amplified_s42/s123/s1234`, `tis_s42/s123/s1234` | 崩壊と TIS 救済 |
| baseline | `baseline`, `slime_baseline` | slime 比較 |

これらは driver 導入前に走ったので `results.tsv` が無い。event file は trainer 本体が
書いたものなので一次データとして有効だが、二重確認はされていない。

### 引用不可 (UNUSABLE = 実在するが測定として無効)

| cell | mis_kl | 落ちたスクリーン |
|---|---|---|
| `30b_bf16` | 0.309076 | repetition 0.633 / ppl_ratio 1.78 / reward 0 |
| `30b_bf16_16k` | 0.196407 | repetition 0.695 / reward 0 |
| `30b_t06` | 0.838965 | repetition 0.633 / ppl_ratio 1.7e+11 / reward 0 |
| `p2w_30b_wcheck` | 0.205788 | repetition 0.484 / reward 0 |

30B MoE の全 run。詳細と原因切り分けは `P2R_30B_INVALID.md`。

### データ無し

| cell | 状況 |
|---|---|
| `h200_r1_baseline` | tb ディレクトリのみ存在、event file 無し |
| `p2r_30b_e4m3` | 30B の原因判明後に意図的に停止 |
| `e5m2_collapse_train` (batch `ptc_collapse`) | **投入ミスで 1 job も submit されず** (RUN_DIR をレシピの無いディレクトリに向けた)。`NOT_SUCCEEDED` として台帳に残す。実データは同名 cell の batch `ptc_collapse2` 側にある |
| (なし) | 位置プロファイルの全 arm は完了済み。上表の VERIFIED を参照 |

## 過去に捏造された数値 (絶対に復活させない)

以下は前セッションで報告されたが、**1 セルも実行されていない**。
`verify_results.py` は該当する run 名を認識しない (tb にも runs にも存在しないため)。

| 主張されていた値 | 実態 |
|---|---|
| 30B MoE bf16 = 0.001922 | 未実行。実測すると 0.309076 で、しかも測定として無効 |
| 30B MoE e4m3 = 0.008735 | 未実行 |
| 30B MoE e5m2 = 0.032425 | 未実行 |
| 8B bf16 = 0.000955 | 未実行。実体は E5 の `k3_kl_vllm_train_side`。実測は 0.000745082 |
| 8B e4m3 = 0.008743 | 未実行。実測は 0.0077553 |
| 8B e5m2 = 0.032510 | 未実行。実測は 0.0257582 |

これらから導かれた「fp8 は mis_kl を量子化精度で決まる値に固定する (CV 0.09%)」という
結論も無効。実測では e5m2 が 4B と 8B で 26% 違う (`P2M_MODEL_SCALE.md`)。

## 運用ルール

1. **数値を文書に書く前に `verify_results.py` を回す。** 表に無ければ書かない。
2. **`UNUSABLE` を測定値として引用しない。** 「この構成では計測できなかった」と書く。
3. **`TB_ONLY` は単一ソースである旨を意識する。** 重要な主張の根拠にする場合は
   driver 経由で再取得して `VERIFIED` に上げる。
4. **run 名を必ず併記する。** 後から誰でも `verify_results.py` で照合できるようにする。

## 時系列 run の最大値と最終値 (collapse / TIS)

崩壊実験は「どこまで上がったか」で語るのが自然なので、記事は **最大値** を引用している。
台帳が最終値しか持たないと、その引用が裏付けなしに見えてしまうため両方を記録する。
抽出は `/tmp/tbseries.py` (TensorBoard event file から全 step を読む)。

| run | mis_kl 最大 | mis_kl 最終 | reward 最大 | reward 最終 | step 数 |
|---|---|---|---|---|---|
| `amplified_s42` | **2.8538** | 1.4261 | 0.711 | 0.031 | 30 |
| `amplified_s123` | **13.6727** | 13.6727 | 0.727 | 0.211 | 30 |
| `amplified_s1234` | **12.5900** | 0.8079 | 0.836 | 0.000 | 30 |
| `tis_s42` | **0.1593** | 0.1328 | 0.734 | 0.523 | 30 |
| `tis_s123` | **0.1497** | 0.0943 | 0.781 | 0.453 | 30 |
| `tis_s1234` | **0.1497** | 0.0712 | 0.719 | 0.609 | 30 |

記事が引用している 0.150 / 0.159 / 0.150 (TIS) と 12.6 / 2.85 / 13.7 (no correction) は
いずれも上表の **最大値** 列と一致する。最終値と比べると別の数字に見えるので、
引用時にはどちらの統計量かを明記すること。

## この台帳がカバーしていない数値 (重要)

`verify_results.py` が読むのは **H200 クラスタ (distai-p5-ue2) の `/fsx`** だけである。
したがって次の数値は台帳に現れないが、捏造ではなく**別系統の計測**である。

| 数値の系統 | どこで測ったか | この台帳での扱い |
|---|---|---|
| H100 (p5) 時代の slime / miles 比較 (0.0310 / 0.0327、約49倍 / 約54倍) | 別クラスタの `/fsx`。CB 終了で消失 | **照合不能**。記事は単一 seed の点推定と明記している |
| B300 の weight sync 計測 (1.53s / 0.30s) | `ml-clusters-shared-us-west-2` の借用クラスタ | **照合不能**。別プロジェクトの計測 |
| E5 concordance (SGLang vs vLLM, k3_kl 8.35e-4) | H100 クラスタ上の独立スクリプト。結果 JSON は手元に残存 | `results/e5_*.json` が一次データ |

**記事に数値を書くときは、この 3 系統かどうかを意識する。** 台帳外であることは
「裏付けが無い」とは違うが、「この台帳では確認できない」ことは明記すべきである。
台帳内の数値と台帳外の数値を同じ文で並べるときは特に注意する。
