# 30B MoE を EP=1 で訓練することはできない (2026-08-04)

> **データ裏付け: NOT_SUCCEEDED** — run `p2v_30b_ep1_bf16` は 2 回とも
> `torch.OutOfMemoryError` で FAILED。ドライバは `metrics withheld: not SUCCEEDED` として
> 数値を記録していない。本ファイルが引用するのは**エラーメッセージ中の要求バイト数だけ**で、
> mismatch 指標は一切含まない。batch `p2v_30b_ep1` (1 ノード) と `p2v_30b_ep1_2node` (2 ノード)。

## 何を試したのか

`moe_probe/` の probe で、30B MoE の反復崩壊の原因が **expert parallelism** だと分かった
(EP=1 なら TP 1/4/8 すべて健全、EP>1 は TP 4/8 すべて崩壊)。

だとすれば **EP=1 で GRPO を回せば、これまで `UNUSABLE` だった 30B の mismatch が測れる**
はずである。台帳のモデル規模軸が 4B/8B の 2 点しか無い理由が解消し、3 点目が入る。
それを試した。

## 結果: 2 回とも CUDA OOM で起動できない

| 試行 | ノード | TP | PP | EP | 結果 | 落ちた時点の要求 | 使用済み |
|---|---|---|---|---|---|---|---|
| 1 | 1 | 8 | 1 | 1 | FAILED | **108.76 GiB** (単発の巨大確保) | 115 GiB |
| 2 | 2 | 16 | 1 | 1 | FAILED | **108.41 GiB** (同上) | 115 GiB |
| 3 | 2 | 8 | **2** | 1 | FAILED | **12 MiB** (最後のわずかな確保) | **125-126 GiB** |

**試行 3 は質的に違う。** 要求が 108 GiB から 12 MiB に落ちており、モデルのロード自体は
通って 125 GiB まで積んだ後、最後の 12 MiB が取れずに落ちている。つまり
**PP=2 は expert 重みの分割に効いている**が、あと数 GiB 足りない。

`MegatronTrainRayActor.init()` の中で落ちる。rollout ではなく **trainer 側**である。

```
torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 108.76 GiB.
GPU 7 has a total capacity of 139.80 GiB of which 20.60 GiB is free.
Including non-PyTorch memory, this process has 115.32 GiB memory in use.
```

## TP を倍にしても要求量が減らない

これが本質的な発見である。TP を 8 -> 16 に倍にしたのに、rank あたりの要求は
108.76 -> 108.41 GiB でほぼ動かない (0.3% 減)。

つまり **tensor parallel はこの 108 GiB を分割していない**。30B MoE の重みの大半は
expert の FFN (48 層 x 128 expert x 3 projection = 18432 テンソル、合計 61 GB) であり、
それを分割するのは EP であって TP ではない。EP=1 は「全 expert を全 rank が持つ」ことを
意味するので、ノードを増やしても 1 rank の負担は変わらない。

## これが意味すること

**EP=1 は反復崩壊の回避策にならない。** probe で「EP=1 なら健全」と分かったが、それは
**推論だけ**の話だった。推論は 61 GB の重みを読むだけで済むが、訓練は optimizer state と
勾配を持つので同じ配置では載らない。

したがって現状の選択肢はこうなる。

| 選択 | 生成品質 | 訓練可否 |
|---|---|---|
| EP=1 | 健全 | **不可** (OOM) |
| EP=2 以上 | 崩壊 (0.594-0.875) | 可 |

**どちらも成立しない。** 30B MoE の mismatch は、EP の反復崩壊が upstream で直るまで
この構成では測れない。台帳の `UNUSABLE` 判定は維持する。

## 未検証: 回避の余地はまだある

以下は時間 (Capacity Block 残り 2 時間) の都合で試していない。

1. **PP=2 の続き (最も近い)。** 試行 3 は 125 GiB まで積んで 12 MiB 足りずに落ちた。
   削る余地は複数ある: `SGLANG_MEM_FRACTION` を 0.5 -> 0.35 に下げる (rollout 側の KV を削る)、
   `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` を入れる (断片化 3.63 GiB の回収)、
   `MAX_TOKENS_PER_GPU` を 8192 -> 4096 に下げる (activation を半減)。
   **どれか 1 つで通る可能性が高い。**
2. **PP=4。** PP=2 で効いたので、さらに層を割れば確実に載る。ただし 16 GPU では
   TP4/PP4/EP1 になり、TP が減る分 activation が増えるトレードオフがある。
3. **`--offload-train`** で trainer 側を CPU に退避する。速度は落ちるが 1 rollout の
   計測だけなら許容できるかもしれない。
4. **より小さい MoE モデル。** モデル規模軸の 3 点目としては「MoE であること」が要件なので
   30B でなくてもよい。EP=1 で載る MoE があればそれで足りる。
5. `--use-distributed-optimizer` は 3 試行すべてで有効だったが、試行 1/2 では
   108 GiB の単発確保を防げていない。要求の主体が optimizer state ではなく
   **重みの複製そのもの**である可能性が高い (PP で減ったことがそれを支持する)。

## 台帳への影響

`DATA_STATUS.md` の 30B 4 セル (`30b_bf16` / `30b_bf16_16k` / `30b_t06` / `p2w_30b_wcheck`) は
引き続き `UNUSABLE` である。本 run は `NOT_SUCCEEDED` として追加する。

モデル規模軸は **4B と 8B の 2 点のまま**であり、`P2M_MODEL_SCALE.md` の
「倍率はモデル依存、移植可能なのはオーダーのみ」という結論も 2 点に基づくままである。
3 点目が入っていないという限界は解消していない。
