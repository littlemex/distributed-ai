# Model schema: facts vs. tuning

Two files describe how a model is served. Keeping them apart is what lets a second engine
serve the same model without copying the model's facts.

## `models/<normalized-id>.yaml` — facts (engine-independent)

Facts are only what is **mechanically verifiable** from the model's `config.json`, tokenizer
config, and license. If a value is a choice rather than a property of the model, it is not a
fact — it belongs in the overlay.

| field | source | example |
|---|---|---|
| `model_id` | HF repo id | `Qwen/Qwen3.8-27B` |
| `architecture` | `config.architectures[0]` | `Qwen3_5ForConditionalGeneration` (`model_type: qwen3_5`) |
| `modality` | pipeline / config | `image-text-to-text` |
| `license` | model card | `apache-2.0` |
| `dtype` | `config.dtype` | `bfloat16` |
| `num_key_value_heads` | config | `4` (tensor-parallel degree must divide this) |
| `max_position_embeddings` | config | `262144` |
| `attention` | `config.layer_types` | `hybrid` (full + linear) |

Two-faced fields go by their nature: `max_position_embeddings: 262144` is a fact; the
`maxModelLen: 32768` you actually launch with is a **tuning choice** → overlay.

## `overlays/<normalized-id>.yaml` — tuning (engine-specific)

Plain Helm values layered on the stack chart's `values.yaml` with `-f`. There is **no merge
engine** — the overlay is just values, `models/` is a referenced fact document.

Typical fields: `image` (SDK-pinned), `tensorParallelSize` / `pipelineParallelSize`,
`maxModelLen`, `gpuMemoryUtilization`, `maxNumSeqs`, `enablePrefixCaching`, `extraArgs`.

Tuning must be justified by facts. Example: Qwen3.8-27B is a hybrid linear-attention model,
so `enablePrefixCaching: false` (recurrent-state layers do not support prefix caching) and a
conservative `maxNumSeqs` (recurrent state, not the KV pool, caps concurrency).

## Normalization rule

The filename is the `model_id` lowercased with `/` → `-` (dots kept): `Qwen/Qwen3.8-27B` →
`qwen3.8-27b.yaml`. The architecture id (`qwen3_5`) is never used as the name.

## Sizing note

Static VRAM arithmetic (weights + KV vs. GPU memory × count) works for standard dense models.
Hybrid / linear-attention models are **out of that formula** — the recurrent state scales with
concurrent sequences, not with context length — so their memory settings are measured and
pinned in the overlay, not computed.
