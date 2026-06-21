# Debug patches (再調査用)

30B MoE の weight sync 形状不一致 (`size of tensor a(64) must match b(2048)`) の
root cause を実測特定するために、SGLang のコードへ一時的に仕込んだ shape ログ patch。

これらは**動作を変えない計測器**（stderr へ shape を出すだけ）で、調査完了後は除去した。
再調査時は image 内の SGLang へ再挿入する。

| patch | 対象ファイル | 出力 |
| --- | --- | --- |
| `akz_patch_model_runner_recv_shape.py` | `sglang/srt/model_executor/model_runner.py` | online weight update で受信した expert weight の name/shape |
| `akz_patch_fused_moe_w13.py` | `sglang/srt/layers/moe/fused_moe_triton/layer.py` | `_load_w13` (gate/up) の expert_data / loaded_weight / shard 情報 |
| `akz_patch_fused_moe_w2.py` | 同上 | `_load_w2` (down) の同情報 |

## 使い方
```bash
# image 内の SGLang へ適用 (各 worker で)
python3 akz_patch_model_runner_recv_shape.py
python3 akz_patch_fused_moe_w13.py
# job 実行後、ログから AKZ_RECV_SHAPE / AKZ_W13 / AKZ_W2 を grep
```

## この patch で判明したこと
- SLIME 送出は HF 標準 `gate_proj=(768,2048)` で正しい
- SGLang param の 36844 件は `(1536,2048)` で整合・成功
- 6 件だけ `(32,1536,64)` の flashinfer_trtllm swizzled レイアウトで非互換 → 400
- → `--sglang-moe-runner-backend triton` で回避
