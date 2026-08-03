# upstream 利用者経路の smoke 確認 (H200, 計装なし)

## 目的

これまでの H200 実験はすべて mismatch 計装付き
(`--get-mismatch-metrics --custom-tis-function-path ... --custom-config-path ...`) で
走らせていた。upstream awsome-distributed-ai の利用者が最初に踏むのは**計装なしの素の
path** なので、そこが通ることを別途確認する必要があった。

いずれも `EXTRA_TRAIN_ARGS=""` (空)、LR 1e-6、NUM_ROLLOUT=1 (save_model バグを踏まない)。
recipe は repo のものをそのまま使用。

## 結果: 3 経路すべて SUCCEEDED

| 構成 | recipe | GPU | 結果 | 稼働 rank | worker IP |
|---|---|---|---|---|---|
| 4B dense / 1 ノード | run_grpo_qwen3_4b.sh | 8 | **SUCCEEDED** | 0-7 (8個) | 1 |
| 4B dense / 2 ノード | run_grpo_qwen3_4b.sh | 16 | **SUCCEEDED** | 0-15 (16個) | 1 |
| 30B MoE / 2 ノード | run_grpo_qwen3_30b_a3b.sh | 16 | **SUCCEEDED** | 0-15 (16個) | **2** |

いずれも `Unexpected number of remote rails` / `ncclInternalError` / `Traceback` が 0 件。

観測値 (参考、計装なしなので mis_kl は出ない):
- 4B 1 ノード: reward 0.484 / grad_norm 0.0559
- 4B 2 ノード: reward 0.523, 0.484
- 30B MoE: grad_norm 0.0994

## 意味

1. **計装フラグは測定のための追加であって、素の学習経路の前提ではない。**
   `EXTRA_TRAIN_ARGS` を空にしても recipe が壊れない (空配列展開を正しく扱っている)。
   upstream の利用者が計装なしで使えることの確認。
2. **2 ノード 16 GPU が素の path でも通る。** rank 0-15 が稼働し、weight sync /
   rollout / Megatron backward がノード境界を EFA 経由で通っている。
3. **MoE の EP all-to-all も通る。** 30B は EP2 の all-to-all を含み、これはノード間
   P2P 的な通信なので、EFA_PER_NODE を allocatable 全数 (15) にした修正が効いている
   ことの確認になる。修正前なら P1 の tp8pp2 と同じ rail 非対称で落ちていた可能性が高い。
   実際 30B の worker IP は 2 個見えており、2 ノードに跨っていることが明確。

## 判定時の注意

`nccl_ofi_gin_init ... Failed to initialize GDRCopy` の警告が 30B で 2 件出るが、
これは GDRCopy を意図的に無効化 (`gpu_operator_enable_gdrcopy=false`) しているため。
`grep -c "NET/OFI"` で数えるとこれを拾って誤判定するので、実エラーは
`Unexpected number of remote rails` か `ncclInternalError` で判定すること。

同様に `actor_cell0_rank[0-9]+` だけを grep すると cell 表記の揺れで rank を取りこぼす。
`actor_cell[0-9]+_rank[0-9]+` で数えること (これで 16 個が正しく出る)。

## 未確認 (upstream README に書くべき限界)

- **B300 は miles では全く未検証。** 別実験で slime の weight sync を B300 で測っているが、
  miles 自体は B300 で 1 度も動かしていない。README には「未計測」と正直に書く。
- **30B disaggregated は H200 では載らない。** HBM 143GB では 30B の静的メモリが
  収まらず、B300 の 288GB が必要。disaggregated は 4B の weight sync 計測でのみ確認。
- 素の path で確認したのは 1 rollout のみ。長時間の学習継続 (checkpoint 保存を含む) は
  この image の Megatron dist-checkpointing バグ
  (`validation.py:521 ValueError: not enough values to unpack`) が既知の障害として残る。
