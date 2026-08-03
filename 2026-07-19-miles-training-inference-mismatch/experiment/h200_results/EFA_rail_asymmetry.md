# 発見: EFA の部分要求が 2 ノード P2P で rail 非対称を起こす (p5 -> p5en で顕在化)

## 症状

P1 の tp8pp2 セル (TP8 x PP2、PP がノード境界を跨ぐ) が投入 4 分で失敗。

```
torch.distributed.DistBackendError: NCCL error ... ncclInternalError: Internal check failed.
Last error:
NET/OFI Unexpected number of remote rails for dev 4. Expected 1 but got 2
NET/OFI Unexpected number of remote rails for dev 0. Expected 2 but got 1
```

aws-ofi-nccl が、あるデバイスについて期待する remote rail 数と実際に見えた数が
2 ノード間で食い違っていると報告している。片方は 1、他方は 2。

## 根本原因

manifest が EFA を**部分的にしか要求していない**ことによる rail トポロジーの非対称。

| 項目 | 値 |
|---|---|
| p5en.48xlarge の EFA 物理枚数 | 16 |
| ノードの allocatable | **15** (1 枚は管理用) |
| manifest の requests/limits | **8** |
| pod に見えるデバイス | 8 |

15 枚のうち 8 枚だけを要求すると、device plugin がどの 8 枚を割り当てるかは
ノードごとに決まる。その結果 2 つの pod で EFA デバイスと NIC rail の対応が
非対称になり、aws-ofi-nccl の rail 検出が食い違う。

H100 (p5.48xlarge) では EFA 32 枚に対して同じ 8 枚要求で動いていた。32 は 8 の
倍数で rail の割り当てが対称になりやすかったためと考えられる。**p5 前提の
マジックナンバー 8 が、EFA 枚数の違う p5en で初めて破綻した**。

## なぜ TP16 では出ないのか

同じ 2 ノード構成でも tp16 (TP=16、PP=1) は正常に進行した。切り分けとして重要:

- **TP16**: 16 GPU 全体が 1 つの TP グループ。ノード間通信は all-reduce のみで、
  全 rank が均一なパターンで参加する。
- **TP8 x PP2**: ノード内 TP8 + ノード間 PP2。ノード間は pipeline の
  **P2P send/recv** になる。rail の非対称性はこの P2P 経路で露呈する。

つまり「2 ノードで all-reduce は通るが P2P は通らない」という状態で、
EFA の疎通確認を all-reduce (nccl-tests の all_reduce_perf 等) だけで済ませていると
この問題を見逃す。**P2P を含む検証が必要**という教訓。

## 対処

EFA 要求を allocatable 全数にする (8 -> 15)。全枚数を要求すれば割り当ての自由度が
なくなり、両ノードで同一の rail トポロジーになる。

より原理的には、manifest に固定値を書かず allocatable から導出すべき。
repo 側には EFA 枚数をインスタンスタイプから導出する仕組み (infra/eks/locals.tf の
efa cards テーブル) があるが、raycluster の requests は手書きの 8 のままだった。

## 影響範囲

- 1 ノード実験 (P1 の intra-node セル 5 つ、既存の H100 結果すべて) は影響なし。
  ノード間通信が発生しないため。
- 2 ノード実験のうち、all-reduce のみのもの (TP16、既存の H100 2 ノード 3 cycle) は
  たまたま通っていた可能性がある。PP や disaggregated の P2P を使うものは落ちる。
- 30B MoE は EP の all-to-all を使うので、P2P 同様に影響を受ける可能性が高い。
  P2 (MoE 実験) の前に必ず修正しておくこと。
