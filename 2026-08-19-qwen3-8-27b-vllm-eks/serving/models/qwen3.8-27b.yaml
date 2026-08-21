# Model facts for Qwen/Qwen3.8-27B.
# FACTS ONLY: everything here is mechanically verifiable from the model's config.json,
# tokenizer, and license. Engine-specific tuning (tp, max_model_len, image tag, flags)
# does NOT belong here -- it lives in serving/values/qwen3.8-27b.values.yaml.
# The normalized filename derives from model_id; the transformers architecture id
# (qwen3_5) is a fact field, never the name.

model_id: Qwen/Qwen3.8-27B
architecture: Qwen3_5ForConditionalGeneration   # model_type: qwen3_5
modality: image-text-to-text                    # VLM (image_token_id present)
license: apache-2.0
dtype: bfloat16
approx_weight_gib: 54
params_total: 27B

# hybrid attention: 16 full_attention + 48 linear_attention (Gated DeltaNet), full every 4th layer
attention: hybrid
num_hidden_layers: 64
full_attention_interval: 4
num_attention_heads: 24
num_key_value_heads: 4          # tensor-parallel degree must divide this: TP in {1,2,4}
head_dim: 256
max_position_embeddings: 262144

# serving-relevant consequences of the architecture (facts, not tuning):
#  - linear_attention layers hold fixed recurrent state, not paged KV -> prefix caching
#    is unsupported on those layers.
#  - requires a vLLM build that registers Qwen3_5ForConditionalGeneration (>= 0.27.0).
