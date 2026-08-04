# P3: weight sync 計測 (colocated TP 掃引 完了)

> **データ裏付け: TB_ONLY (単一ソース)** — 本ファイルの数値は run `h200_p3_colo_tp1` / `tp2` / `tp4` / `tp8` の TensorBoard event file に
> 由来する。判定と引用可否の定義は同ディレクトリの `DATA_STATUS.md`、照合コマンドは
> `python3 verify_results.py` (Ray head pod)。数値を他の文書へ転記する前に必ず照合する。


問い: B300 で得た「colocated (CUDA IPC) は disaggregated (NCCL/EFA) より 5 倍遅い
(1.5s vs 0.3s)」は H200 で再現するか。事前予測は「原因は ipc_collect() GC と Ray IPC
handle 往復というソフト要因なのでハード不変で再現する」。

条件: Qwen3-4B, colocated, LR 1e-6, NUM_ROLLOUT=1, 1 ノード 8GPU。
**全 rank の update_weights サンプルを収集** (P1 で rank 間に散ることが判明したため、
tail -1 の単一サンプルでは比較できない)。

| TP | n(rank) | min | **median** | max | mean | mis_kl (P1 と一致) |
|---|---|---|---|---|---|---|
| 1 | 2 | 0.50 | **0.50** | 0.50 | 0.50 | 0.000627 |
| 2 | 8 | 1.20 | **1.35** | 1.80 | 1.41 | 0.000648 |
| 4 | 8 | 0.90 | **1.15** | 1.30 | 1.12 | 0.000586 |
| 8 | 8 | 1.00 | **1.15** | 1.30 | 1.15 | 0.000710 |

mis_kl は P1 の対応セルと完全一致しており、測定の再現性が取れている。

## 結論1: TP1 と TP>1 の間に段差がある (単調増加ではない)

TP を上げるほど遅くなるのではない。**TP=1 が 0.5s で特異に速く、TP2/4/8 は
中央値 1.15-1.35s で横並び**という段差構造である。TP2 -> TP8 で 4 倍並列度が
上がっても weight sync はほぼ変わらない。

機構としては、TP=1 では各 rank が持つ重みが連続した 1 枚のテンソルなので CUDA IPC の
handle が最小個数で済み、TP>1 では shard 化により handle 数と ipc_collect() の GC 対象が
増える、という説明が整合する。ただし shard 数は TP に比例するのに時間は比例しないので、
支配項は handle 数そのものではなく「shard 化しているか否か」の固定コストと思われる。

## 結論2: B300 の「colocated は 5 倍遅い」は TP 交絡ではなかった (仮説を棄却)

TP1 で 0.5s、TP>1 で 1.15-1.35s という段差を見て「B300 の colocated 1.5s は TP>1 の値で、
disaggregated 0.3s は TP1 の値だったのではないか (= 5 倍差は方式差ではなく TP 差)」と
疑った。B300 実験の env を確認して**この仮説は棄却**した。

`2026-06-21-slime-rl-weight-sync-b300/recipe/env_vars.*.example` の 3 構成すべてが
**TP_SIZE=1**、ACTOR 1 ノード 8 GPU、ROLLOUT 8 GPU である (colocated-4b は
COLOCATE=true、disaggregated-4b と -30b-moe は false、TP はいずれも 1)。
同じ TP1 同士の比較だったので、**colocated 1.5s vs disaggregated 0.3s の 5 倍差は
方式差として正しい**。既存の結論と ipc_collect()/Ray IPC handle への帰属は維持される。

## 結論3: 定常値を取り直した結果、B300 の colocated だけが異常に遅い

当初 NUM_ROLLOUT=1 では初回 (接続確立込み) しか測れず B300 の定常値と比較できなかった。
NUM_ROLLOUT=3 で走らせ、save_model バグで FAILED になる前にログから回収して定常値を得た
(job は赤だが測定値は有効)。

### H200 colocated の内訳 (TP1 と TP8)

| TP | 初回 (接続込み) | **定常 (2-3 回目)** | 全 rank 分布 (定常含む全サンプル) |
|---|---|---|---|
| 1 | 0.5s | **0.4s** | 0.4 x16, 0.5 x8 (ばらつきなし) |
| 8 | 1.2s | **0.9s** (median 0.85) | 0.8 x14, 0.9 x9, 1.0/1.1/1.2 x1 |

TP1 は全 rank 全呼び出しで完全に一定。TP8 は 0.8-0.9 に集中し外れ値が 3 個。
どちらも初回より定常が速く、接続確立コストが初回に乗る構造が確認できた。
これで B300 の報告と同じ「定常・全 rank」の土台になった。

TP1/TP8 の段差は定常でも残る (0.40 vs 0.85 = 2.1 倍) が、初回同士 (0.5 vs 1.2 = 2.4 倍)
より縮む。段差の一部は接続確立時の handle セットアップに由来し、残りは転送本体の
shard 化コストということになる。

### B300 との比較 (同一条件: Qwen3-4B / colocated / TP1 / 定常 / 全 rank)

| 環境 | HBM | colocated 定常 | disaggregated 定常 |
|---|---|---|---|
| B300 (p6-b300) | 288GB | **1.53s** (TP1) | 0.30s (TP1) |
| H200 (p5en) | 143GB | **0.40s** (TP1) / 0.85s (TP8) | (未測定) |

**B300 の colocated が H200 の 3.8 倍遅い**。しかも H200 の colocated 0.40s は
B300 の disaggregated 0.30s とほぼ同水準で、**H200 で TP8 まで上げた 0.85s ですら
B300 の TP1 colocated 1.53s より速い**。TP の効果 (2.1 倍) では環境差 (3.8 倍) を
説明できない。

### これが意味すること

既存の帰属は「colocated が遅いのは CUDA IPC の chunk ごとの ipc_collect() GC と
Ray IPC handle 往復というソフト要因であり、方式に内在するコスト」だった。
B300 内部の比較 (colocated 1.53 vs disaggregated 0.30 = 5.1 倍) はその通りなので、
**方式差そのものは B300 上の事実として維持される**。

しかし H200 では colocated でも 0.40s 出る。同じフレームワーク・同じモデル・同じ TP で
3.8 倍違うので、**B300 の 1.53s は方式に内在するコストではなく B300 環境固有の
上乗せを含んでいる**。つまり「colocated は CUDA IPC のせいで本質的に 5 倍遅い」と
一般化してはいけない。正しくは「B300 環境では colocated が 5 倍遅かった。H200 では
その差はずっと小さい可能性が高い (disaggregated の測定待ち)」となる。

上乗せの候補は以下。今回の測定では切り分けきれていない。
1. フレームワーク世代差 (B300 は slime、今回は miles フォーク)。CUDA IPC の
   chunk 処理が変わっていれば効く。H200 上で slime image を回せば分離できる。
2. CUDA/ドライバ世代差 (B300 は sm_103 / CUDA 13 系、H200 は sm_90)。
   `cudaIpcGetMemHandle` のコストや GC 挙動が違いうる。
3. B300 側の既知の workaround (MemPool/memory_saver 系の patch や
   `--no-offload-train/rollout`) が IPC 経路に副作用を持っていた可能性。

なお事前予測「ソフト要因なのでハード不変、H200 でも 1.5s が再現する」は**外れた**。
weight sync のコストは環境依存性が強く、単一環境の絶対値を他環境に持ち込めない。

## 追記 (2026-08-04): disaggregated を測った。この節の残タスクは解消した

下の残タスク一覧の 1 番目「disaggregated x TP{1,8} x 4B」を実測した。結果は
`P3M_METHOD_MATRIX.md` にある。要点だけ:

- **H200 disaggregated の定常は 0.170s** (mem-fraction 0.8、7 rollout、CV 0.013、STEADY)。
  同条件の colocated は 0.482s なので **方式差は 2.84 倍**。B300 の 5.1 倍ではない。
- **この節の「colocated 定常 0.40s」は基準が甘かった。** 3 rollout の 2-3 周目を定常と
  呼んでいたが、B300 では 4 周目以降が定常だったので自分たちの観測と矛盾していた。
  7 rollout で先頭 3 つを捨てて測り直すと 0.482s である。
- **なぜ今まで測れていなかったか**: recipe が `--colocate` をハードコードしていて、
  `COLOCATE` 変数は banner の echo にしか使われていなかった。`COLOCATE=false` を書いても
  disaggregated にはならず、このアームはハーネスから到達不能だった。upstream の
  miles test case 側で修正済み。
- **2.84 倍は「転送方式の差」ではない。** colocated 経路だけが sync ごとに
  `pause_generation` + `flush_cache` を呼ぶ (`update_weight_from_tensor.py:213-215`)。
  正しくは「配置を変えたときの weight sync 総コストの差」である。

以下の残タスク一覧は当時のまま残す。1 番目は上記で解消、2-3 番目は未実施。

## 残タスク

- disaggregated x TP{1,8} x 4B の 2 セル: 「TP を揃えても方式差は残るか」の核心。
  ノード跨ぎ (trainer をノード A・rollout engine をノード B) に置いて純 EFA パスを測る。
  ここで H200 の disaggregated が 0.3s 級なら B300 と方式差だけが一致し、
  結論 3 は「colocated 側のみが環境依存」という形に絞れる。
- colocated x TP1 x {1.7B, 8B}: サイズスケーリング (切片=レイテンシ支配と
  傾き=帯域支配の分離)。
- B300 の生ログから全 rank サンプルを引き直す (実機不要)。
