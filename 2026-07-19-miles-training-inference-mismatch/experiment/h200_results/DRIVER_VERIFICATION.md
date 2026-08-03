# 実験ドライバの検証記録 (2026-08-03)

捏造事故を受けて、ドライバを「走っていないことを数値で埋められない」構造に作り替え、
Fable レビュー 2 巡と実機スモークランで検証した。その記録。

## なぜ作り直したか

事故の直接原因は「結果を報告する経路に、実行の裏付けを確認する仕組みが無かった」こと。
旧 `run_p2.sh` は submit 直後に `ray job status` を 1 回叩くだけで、しかも

- 完了を待たない (RUNNING のまま次に進む)
- status が取れなければ空文字になる
- メトリクスが取れなければ空文字になる

ため、「1 セルも投入されていないバッチ」と「全セル成功したバッチ」の出力が
見分けられなかった。だから最優先の設計要件を「terminal state を明示し、
SUCCEEDED 以外では metric 列を必ず `-` にする」に置いた。

## Fable レビューで見つかった blocker (2 巡)

### 第 1 巡

| 指摘 | 対応 |
|---|---|
| `mis_dump` が CP=2 で壊れる (Megatron の zigzag 分割) | CP=1 限定ガード。docstring に理由 |
| `use_tis=False` でダンプ 0 件の可能性 | 実機スモークで **120 ファイル生成を確認** |
| `RUN_DIR=/tmp` + 相対 source | `run_batch.sh` を自身の位置基準の絶対 source に |
| FSx ライフサイクル | **PERSISTENT_2 と確認**。teardown で消えない |
| job 完了待ちなし / status 誤判定 | 下記の通り実装 |

### 第 2 巡 (第 1 巡の修正版に対して)

| 指摘 | severity | 対応 |
|---|---|---|
| recipe がブロックするので `EXP_TIMEOUT` がデッドコード | blocker | `timeout` で recipe 自体を包み、rc=124 で `ray job stop` してから TIMEOUT 行を書く |
| **prompt offset が宣言だけでコードに無い** | blocker | `token_slope()` を新設し x = `prompt_len + idx` に。旧 bin 版は表示専用に降格 |
| `_cp_size` の fail-open (except → 1) | blocker | `args.context_parallel_size` と mpu をクロスチェックし、不明・不一致は `None` = ダンプ拒否 |
| TP>1 で全 TP rank が同一データをダンプ | major | `_is_tp_rank_zero()` で TP rank 0 のみ + 解析側で内容ハッシュ dedupe |
| mu 推定ノイズが k² 項を再導入し alpha_within を上に偏らせる | major | 隣接ペア差分に置換 (推定ノイズゼロでバイアスが厳密に消える) |
| SUCCEEDED なのに joblog 空 → 全列 `-` | major | submit.log にフォールバック (recipe がストリームしている) |
| head 死亡時にセルごと最大 4h を浪費 | major | `NOT_FOUND` / `UNREACHABLE` を分離し、後者は 5 分で見切る |
| 引数ゼロで「batch complete」 | major | `$# -eq 0` を FATAL |
| 派生パスと `EXTRA_TRAIN_ARGS` が unquoted | major | すべて `shlex.quote`。cell 名も `[A-Za-z0-9._-]+` 検証 |

## 実機で確認した事実 (推測ではなく実測)

1. **`ray job status` の CLI 出力は `status: X` 形式ではない。**
   実際は `Job 'raysubmit_xxx' succeeded` が ANSI カラー付きで出て、FAILED ジョブでは
   さらに `Status message: Job entrypoint command failed...` が続く。素朴な grep は
   本文の "failed" を拾う。→ CLI パースを捨て Python SDK の `get_job_status()` に。
   実機の SUCCEEDED / FAILED 両ジョブで正しく `SUCCEEDED` / `FAILED` を返すことを確認。

2. **`compute_mis_weights_with_cp` は CP スライスを受け取る。**
   docstring に "log probs from training backend on this cp rank" と明記され、
   関数内部で `all_gather_with_cp` してから `slice_cp_and_concat` で戻している。

3. **`use_tis` の early return は `compute_mis_weights` の内部 (mis.py:209)**、つまり
   `compute_mis_weights_with_cp` より下層。よって wrapper は baseline でも呼ばれる。
   ただしこれは状況証拠なので、スモークランで npz 生成を実測して確定させた。

4. **`MIS_DUMP_*` は recipe の `runtime-env-json` に無かった** ので worker に届かない。
   recipe に 3 行追加した。これは env を書くだけでは動かない類の穴で、
   スモークランなしには気付けなかった。

## スモークラン結果 (全経路の実測)

`sm_dump1` (4B / TP1 / step 0 / `MIS_DUMP_EVERY=1`)

| 検証項目 | 結果 |
|---|---|
| env 生成 (spec sha 記録付き) | OK |
| submit → 完了待ち | OK `SUCCEEDED` |
| メトリクス抽出 vs TensorBoard | **完全一致** `0.00062454619910568` vs tb `0.000624546` |
| per-token ダンプ | **120 ファイル / 128 系列 / 6.2MB** |
| 解析がダンプを読める | OK (重複 0 / 読取失敗 0) |
| **ジョブ未投入時の挙動** | **`NO_JOB` を記録し数値を埋めない** (実際に 1 回発生した) |

最後の行が今回いちばん重要である。最初の起動は `ACTOR_NUM_NODES` 未設定で recipe が
即エラー終了したが、ドライバは `NO_JOB` 行を書いて metric 列を `-` にした。
旧ドライバならここで空文字が並び、それを人間が埋める余地があった。

## メトリクス抽出のテスト

実ログ 1 本 (`p3_colo_tp4.log`) で 6 指標すべてが TensorBoard と一致。加えて合成ログで:

| ケース | 期待 | 実測 |
|---|---|---|
| `train/mis_kl` と `train/mis_kl_extra` の前方一致 | 混同しない | OK (0.0006 / 999.0 を正しく区別) |
| `nan` | `nan` | OK |
| `inf` | `inf` | OK |
| 負の指数 `-1.6e-11` | そのまま | OK |
| キー欠損 | `-` | OK |
| ファイル欠損 | `-` | OK |

## 解析コードのテスト (合成データで正解を既知にした)

3 種の生成器で検証。傾き判定は 3 種すべて正解:

| 生成器 | 真の構造 | slope 判定 | alpha_within (真値) |
|---|---|---|---|
| flat | 位置依存なし | flat (CI がゼロを含む) | 1.07 (1) |
| grow | \|r\| が位置に比例 | accumulating (CI がゼロを除外) | **1.94** (2) |
| seqbias | 系列ごと定数バイアスのみ | flat | **0.90** (1) |

隣接ペア差分に替える前は grow が 1.75、seqbias が 1.51 で、どちらも真値から離れていた。
Fable の指摘通り、mu 推定ノイズが k² でスケールして alpha を持ち上げていた。

**報告を諦めた統計量がある。** 「Var[cumsum] のうち系列間バイアスが占める割合」の
点推定は 2 つの推定量を試し、どちらも合成データで不可能な値を返した
(バイアス 0 のデータで 91%、grow で 172%)。系列内定常性を仮定するためで、
それはまさに検証対象なので、点推定を出さず `alpha_raw` vs `alpha_within` の
比較に置き換えた。

## bf16 baseline の位置プロファイル (スモークランの副産物)

`sm_dump1` の 128 系列 (min_len 8044 で 64 系列) より:

- \|r\| の絶対位置に対する傾き: **-3.21e-07 /token** (95%CI [-4.35e-07, -1.90e-07])
  → 8044 トークンで -18.4%。**わずかに減少**しており、増加はしていない
- `alpha_raw` 0.73 / `alpha_within` 1.03 → 系列内では実質 i.i.d.

つまり bf16 は「位置に対してフラット」という予測と整合する。これが fp8 アームの対照群になる。

## 現在のコード所在

| ファイル | 用途 |
|---|---|
| `/Users/akazawt/tmp/distai-p5-ue2-miles/lib/experiment.sh` | ドライバ本体 (sha c0ca910301c7) |
| `/Users/akazawt/tmp/distai-p5-ue2-miles/run_batch.sh` | 絶対 source するエントリポイント |
| `/Users/akazawt/tmp/distai-p5-ue2-miles/lib/gen_cells.py` | spec からの env 生成 |
| `/Users/akazawt/tmp/distai-p5-ue2-miles/mis_dump.py` | per-token ダンプ計装 |
| `/Users/akazawt/tmp/distai-p5-ue2-miles/analyze_position_profile.py` | 位置プロファイル解析 |
| `/Users/akazawt/tmp/distai-p5-ue2-miles/specs/` | 実験 spec (smoke.json, p2m_8b.json) |
| `/Users/akazawt/tmp/distai-p5-ue2-miles/fable_review2_out.md` | Fable 第 2 巡レビュー全文 |
