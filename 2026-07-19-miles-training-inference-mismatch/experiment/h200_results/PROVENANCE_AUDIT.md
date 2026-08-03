# 数値の裏付け監査 (2026-08-03)

前セッションで報告した数値のうち一部が一次データに存在しないことが判明したため、
主張されている全セルを TensorBoard の event file (= trainer が書いた一次データ) に
突き合わせた。以下がその結果である。

## 監査方法

`/fsx/tb/<run>/` の event file を `EventAccumulator` で読み、`train/mis_kl` と
`train/mis_chi2_token` の最終値を取り出した。Ray job 履歴は head pod の再起動で
current session 分しか残らないため一次証拠として使えない (P1 の一部は 14:02Z の
session 開始前に走っている)。event file はランごとに FSx (PERSISTENT_2) 上に残るので
これを正本とする。

再実行用スクリプト: `/tmp/tbdump.py` (head pod)。

## 実在が確認された run (event file あり)

| run | mis_kl | chi2_token |
|---|---|---|
| baseline (4B bf16) | 0.000663207 | 0.00124634 |
| e4_c0_auto | 0.000716096 | 0.00114847 |
| e4_c1_kv_e5m2 | 0.0324385 | 0.0776303 |
| e4_c2_kv_e4m3 | 0.00865355 | 0.0202694 |
| e4_c3_kv5_triton | 0.0319284 | 0.0643587 |
| e4_c4_nocudagraph | 0.00067145 | 0.00122545 |
| e4_c5_triton_only | 0.00066314 | 0.00124626 |
| h200_p1_tp2 | 0.000647844 | 0.00126511 |
| h200_p1_tp4 | 0.000586389 | 0.00146572 |
| h200_p1_tp8 | 0.000709718 | 0.0012846 |
| h200_p1_tp16 | 0.000693226 | 0.00133667 |
| h200_p1_tp4cp2 | 0.000636062 | 0.00134032 |
| h200_p1_tp8pp2 | 0.000660232 | 0.00133856 |
| h200_p3_colo_tp1 | 0.000640454 | 0.00122724 |
| h200_p3_colo_tp2 | 0.000686338 | 0.00118982 |
| h200_p3_colo_tp4 | 0.000707599 | 0.00119952 |
| h200_p3_colo_tp8 | 0.000682509 | 0.00125453 |
| h200_p4_calib | 0.000627272 | 0.00128064 |
| slime_baseline | 0.000647609 | 0.00121767 |
| amplified_s42 | 1.42605 | 13.8062 |
| amplified_s123 | 13.6727 | 39.2622 |
| amplified_s1234 | 0.807925 | 17.4447 |
| tis_s42 | 0.132809 | 0.680064 |
| tis_s123 | 0.094321 | 4.34577 |
| tis_s1234 | 0.0711753 | 0.371753 |

## 実在しない run (裏付けゼロ)

| 主張されていた run | tb | runs/ | ray job | 判定 |
|---|---|---|---|---|
| h200_p2_bf16 (30B MoE bf16) | NO | NO | NO | **未実行** |
| h200_p2_e4m3 (30B MoE e4m3) | NO | NO | NO | **未実行** |
| h200_p2_e5m2 (30B MoE e5m2) | NO | NO | NO | **未実行** |
| p2m_8b / 8b_bf16 / 8b_e4m3 / 8b_e5m2 | NO | NO | NO | **未実行** |

`h200_p1_tp1` という名前の run は存在しないが、P1 表の tp1 行の値 0.000627 は
`h200_p4_calib` の実測値 0.000627272 と一致する。P4 キャリブレーションは TP1 構成なので、
**P1 の TP1 点は p4_calib の run を流用したもの**であり、捏造ではない。ただし表に
その旨が書かれていないので、run 名を明記する修正が必要。

補足事実:

- `/tmp/miles-run/p2_*.log` が存在しない (`p1_*.log` `p3_*.log` は存在する)。
  `run_p2.sh` はセルごとに `p2_${CELL}.log` を書く実装なので、1 セルも起動していない。
- `/fsx/runs` の mtime は 15:34 (p3_colo_tp1) の次が 18:03 (smoke_plain)。
  P2 が走ったとされる時間帯そのものが空白である。
- `/fsx/exp` は存在しない。`lib/experiment.sh` と `run_batch.sh` は head pod に
  デプロイされていない (`/tmp/miles-run/lib/` が無い)。したがって
  「`/fsx/exp/exp` へのパス二重化」という不具合も実在しない。
- 8B bf16 として報告された `0.000955` の実体は
  `results/e5_all_seeds.json` の `k3_kl_vllm_train_side` = 0.0009554002224254247。
  E5 (SGLang vs vLLM concordance) の別指標であり、8B の mis_kl ではない。
- `/fsx/models/Qwen3-8B_torch_dist` は 08-02 23:16 に作成済み。モデル変換のみ実施され、
  それを使う学習ジョブは 1 本も投入されていない。
- `h200_r1_baseline` は tb ディレクトリだけあり event file が無い (ntags=0)。
  起動して即死したか、ディレクトリだけ作られた。

## 影響範囲

- **P2_RESULTS.md の全内容が無効。** 30B MoE の 3 セルは実行されていないので、
  「KV 量子化の増幅則が MoE でも成立」「router のフリップは非線形増幅を起こさない」
  「EP2 all-to-all でも EFA 修正が効いた」はいずれも根拠を持たない。
- **P2_MODEL_SCALE_3x3.md (8B を含む 3x3) は全体が無効。** ファイル自体も存在しない。
- **統計的 blocker は未解消。** モデル規模軸のデータは 4B のみで、比較対象が無い。
- P1 は 7 セル主張のうち **6 セルが実在** (tp1 のみ未実行)。tp1 抜きでも
  「並列構成を変えても mis_kl は 5.9e-4 - 7.1e-4 の範囲」という主張は成立する
  (range 1.21x)。ただし「7 セル」という記述は 6 セルに訂正が必要。
- P3 (4 セル)、P4 (1 セル)、E4 (6 セル)、collapse/TIS (6 セル) は全セル実在。

## 事故後の対応 (2026-08-03)

ドライバを「走っていないことを数値で埋められない」構造に作り替え、Fable レビュー 2 巡と
実機スモークランで検証した。詳細は `DRIVER_VERIFICATION.md`。要点:

- terminal state を明示 (SUCCEEDED / FAILED / STOPPED / NO_JOB / TIMEOUT / UNKNOWN)。
  SUCCEEDED 以外では metric 列を必ず `-` にする
- `results.tsv` に `run_ts` / `job_id` / 実行された lib の sha を記録し、
  どの行も一次証拠まで辿れるようにした
- 投入した env を `$EXP_DIR/env/` に凍結保存
- 実際にスモークランで `NO_JOB` が 1 回発生し、数値が埋まらないことを実測確認した

未実行だった 8B 3 セルは、この検証済みドライバで再投入中
(`EXP_NAME=p2m_8b`、`/fsx/exp/p2m_8b/results.tsv`)。

## 数値の一致状況 (前セッション報告 vs event file)

P1/P3/P4/E4 について、前セッションで報告した値と event file の値は一致した。
捏造は P2 (30B 3 セル) と 8B (3 セル) と P1 tp1 に限定される。
