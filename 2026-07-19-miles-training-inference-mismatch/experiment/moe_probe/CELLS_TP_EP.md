# TP と EP を分離する追加セル (設計)

`B_tp1` は TP4/EP2 -> TP1/EP1 で **2 軸を同時に**動かしたので、
反復崩壊が TP に起因するか EP に起因するかを分離していない。次の 2 セルで決まる。

| cell | TP | EP | 動かす軸 | この結果なら何が言えるか |
|---|---|---|---|---|
| `F_tp4_ep1` | 4 | **1** | EP のみ (A から EP を落とす) | 反復すれば **TP が原因**。EP は無関係 |
| `G_tp1_ep2` | **1** | 2 | TP のみ (A から TP を落とす) | 反復すれば **EP が原因**。TP は無関係 |

事前宣言 (結果を見る前に固定する):

- `F` が反復し `G` が健全 -> TP sharding が原因。`moe_intermediate_size=768` を TP で割った
  値 (TP4 -> 192) と kernel の alignment 要求の関係を次に疑う。
- `F` が健全で `G` が反復 -> EP (expert 配置 / all-to-all dispatch) が原因。
- 両方反復 -> TP と EP が独立に壊す。あるいは「shard 化そのもの」が条件。
- 両方健全 -> TP と EP の**組み合わせ**でのみ壊れる。最も厄介な結論で、
  TP2/EP2 や TP4/EP4 に広げる必要がある。

実行 (probe pod が生きている前提、各セル約 5 分):

```bash
bash run_cells.sh F_tp4_ep1:0,1,2,3 G_tp1_ep2:0,1
```

`probe.py` の `CELLS` に以下を足す必要がある。**まだ足していない** (CB の残り時間を
weight sync の完走に充てたため)。

```python
    "F_tp4_ep1": dict(  # 動かす軸: EP のみ (A_repro から EP2 -> EP1)
        model="/fsx/models/Qwen3-30B-A3B", tp=4, ep=1, backend="triton",
        sampling=MILES_SAMPLING),
    "G_tp1_ep2": dict(  # 動かす軸: TP のみ (A_repro から TP4 -> TP1)
        model="/fsx/models/Qwen3-30B-A3B", tp=1, ep=2, backend="triton",
        sampling=MILES_SAMPLING),
```

注意: `G_tp1_ep2` は TP1 で EP2 を要求するので、SGLang が
`ep_size <= tp_size` を要求する場合は起動が失敗しうる。失敗した場合はそれ自体が
「EP は TP に従属する」という構造の証拠になるので、エラーメッセージを記録して
`F` の結果だけで TP 帰属を判断する。
