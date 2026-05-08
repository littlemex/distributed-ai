"""EXP-1037: Stockmark-DocReasoner-Qwen2.5-VL-32B text backbone for NxD Inference.

Based on NxDI's existing `neuronx_distributed_inference.models.qwen2_vl.modeling_qwen2_vl_text`
(Qwen2-VL), adapted for Qwen2.5-VL specific config:
  - hidden_size=5120, layers=64, 40 Q / 8 KV (GQA 5:1), rope_theta=1e6
  - rope_scaling={'mrope_section': [16,24,24], 'type': 'default'} (Qwen2-VL used 'mrope')
  - tied_word_embeddings=False
  - weight key prefix: `model.*` (pure Qwen2.5-VL), `lm_head.weight`, `visual.*` (skipped here)

Step 1 scope: text-only (ignore vision), 1-layer cos vs HF CPU reference.
"""

import gc
import logging
from typing import Optional, Tuple, List, Type

import torch
from torch import nn

from neuronx_distributed.parallel_layers import parallel_state
from neuronx_distributed.parallel_layers.layers import (
    ColumnParallelLinear,
    ParallelEmbedding,
)
from neuronx_distributed.utils import cpu_mode

from neuronx_distributed_inference.models.config import InferenceConfig, NeuronConfig
from neuronx_distributed_inference.models.llama.modeling_llama import NeuronLlamaMLP
from neuronx_distributed_inference.models.model_base import (
    NeuronBaseForCausalLM,
    NeuronBaseModel,
)
from neuronx_distributed_inference.modules.attention.attention_base import (
    NeuronAttentionBase,
)
from neuronx_distributed_inference.modules.attention.utils import _rotate_half
from neuronx_distributed_inference.modules.custom_calls import CustomRMSNorm
from transformers.models.llama.modeling_llama import LlamaRMSNorm

logger = logging.getLogger("Neuron")


# ---------------------------------------------------------------------------
# Multimodal RoPE (identical to Qwen2-VL)
# ---------------------------------------------------------------------------


def apply_multimodal_rotary_pos_emb(q, k, cos, sin, mrope_section, unsqueeze_dim=1):
    mrope_section = mrope_section * 2
    split_indices = [sum(mrope_section[: i + 1]) for i in range(len(mrope_section) - 1)]
    cos = torch.cat(
        [m[i % 3] for i, m in enumerate(torch.tensor_split(cos, split_indices, dim=-1))],
        dim=-1,
    ).unsqueeze(unsqueeze_dim)
    sin = torch.cat(
        [m[i % 3] for i, m in enumerate(torch.tensor_split(sin, split_indices, dim=-1))],
        dim=-1,
    ).unsqueeze(unsqueeze_dim)

    q_embed = (q * cos) + (_rotate_half(q) * sin)
    k_embed = (k * cos) + (_rotate_half(k) * sin)
    return q_embed, k_embed


def get_rmsnorm_cls():
    return LlamaRMSNorm if cpu_mode() else CustomRMSNorm


class NeuronStockmarkTextRotaryEmbedding(nn.Module):
    """3-axis multimodal rotary embedding for Qwen2.5-VL text backbone.

    Takes position_ids of shape [3, batch, seq_len] (temporal/height/width).
    For text-only, all 3 axes contain identical 1-D positions.

    HF Qwen2_5_VLRotaryEmbedding.forward (transformers v4.57.6, L513-L526) の
    position_ids 規約:
      - 入力は [3, B, S] (temporal/height/width の 3 軸)
      - inv_freq_expanded: [3, B, dim/2, 1]  ← position_ids.shape[1] = B を参照
      - position_ids_expanded: [3, B, 1, S]

    NxDI adapter (HuggingFaceGenerationAdapter) は 2D [B, S] を渡すため、
    2D を受けた場合は 3 軸 replicate する。text-only では 3 軸同値で正しい。

    NOTE: TKG (decode) 時に adapter から渡される position_ids の「値」が
    HF と一致するかは NeuronStockmarkTextForCausalLM.prepare_inputs_for_generation
    で rope_delta 補正を行うことで担保する。
    """

    def __init__(self, config: InferenceConfig, device=None):
        super().__init__()
        self.dim = getattr(
            config, "head_dim", config.hidden_size // config.num_attention_heads
        )
        self.base = getattr(config, "rope_theta", 1000000.0)
        self.attention_scaling = 1.0
        self.register_buffer("inv_freq", None, persistent=False)
        self.inv_freq = self.get_inv_freqs(device)

    def get_inv_freqs(self, device: Optional[torch.device] = None) -> torch.Tensor:
        freq_indices = torch.arange(0, self.dim, 2, dtype=torch.float32, device=device)
        return 1.0 / (self.base ** (freq_indices / self.dim))

    def forward(self, x, position_ids):
        # NxDI standard caller passes position_ids as [B, S] (2-D).
        # Qwen2.5-VL M-RoPE expects [3, B, S] (temporal/height/width).
        # For text-only runs the single axis is replicated 3x -- numerically
        # identical to HF's get_rope_index text-only path (L1128-1133) which
        # also expands 1D positions to 3 equal axes.
        if position_ids.dim() == 2:
            # [B,S] -> [3,B,S]
            position_ids = position_ids.unsqueeze(0).expand(3, -1, -1)
        # position_ids is now [3, B, S]
        # Match HF L516: inv_freq_expanded uses position_ids.shape[1] = B
        inv_freq_expanded = self.inv_freq[None, None, :, None].expand(
            3, position_ids.shape[1], -1, 1
        )
        # Match HF L517: position_ids[:, :, None, :] -> [3, B, 1, S]
        position_ids_expanded = position_ids[:, :, None, :].float()

        device_type = (
            x.device.type
            if isinstance(x.device.type, str) and x.device.type != "mps"
            else "cpu"
        )
        with torch.autocast(device_type=device_type, enabled=False):
            # freqs: [3, B, dim/2, 1] @ [3, B, 1, S] -> [3, B, dim/2, S]
            # .transpose(2,3) -> [3, B, S, dim/2]
            freqs = (inv_freq_expanded.float() @ position_ids_expanded.float()).transpose(
                2, 3
            )
            emb = torch.cat((freqs, freqs), dim=-1)  # [3, B, S, dim]
            cos = emb.cos() * self.attention_scaling
            sin = emb.sin() * self.attention_scaling
        return cos.to(dtype=x.dtype), sin.to(dtype=x.dtype)


# ---------------------------------------------------------------------------
# Attention (GQA, M-RoPE, qkv_bias=True, o_bias=False)
# ---------------------------------------------------------------------------


class NeuronStockmarkTextAttention(NeuronAttentionBase):
    def __init__(self, config: InferenceConfig, tensor_model_parallel_group=None):
        head_dim = getattr(
            config, "head_dim", config.hidden_size // config.num_attention_heads
        )
        super().__init__(
            config=config,
            tensor_model_parallel_group=tensor_model_parallel_group,
            hidden_size=config.hidden_size,
            num_attention_heads=config.num_attention_heads,
            num_key_value_heads=config.num_key_value_heads,
            head_dim=head_dim,
            num_cores_per_group=getattr(config, "num_cores_per_group", 1),
            qkv_bias=True,
            o_bias=False,
            rotary_emb=NeuronStockmarkTextRotaryEmbedding(config),
            rms_norm_eps=config.rms_norm_eps,
        )
        self.rope_theta = config.rope_theta
        self.rope_scaling = config.rope_scaling
        self.mrope_section = config.rope_scaling["mrope_section"]

    def apply_rotary_embedding(
        self, Q, K, V, position_ids, cos_cache, sin_cache, use_polar_compatible_rope
    ):
        # Root cause of TKG divergence (Agent investigation 2026-05-07):
        # NxDI's NeuronAttentionBase passes cos_cache/sin_cache across
        # decoder layers. In the CTE NEFF we computed cos_cache of shape
        # [3, B, S_cte, dim]; when the TKG NEFF starts calling us with
        # position_ids of shape [B, 1], cos_cache is already non-None so
        # the `if cos_cache is None` guard skips the recompute and every
        # decode step reuses CTE's rotary at position ~S_cte-1. This makes
        # the model hallucinate the same token forever (English: "Paris."
        # loop, Japanese: digit/hiragana repetition).
        #
        # Force recompute when the current call is a token-generation step
        # (seq_len == 1 on position_ids) so each new token gets its own
        # correct cos/sin for its absolute position.
        if self.rotary_emb is not None:
            # NxDI propagates cos_cache/sin_cache across decoder layers, which
            # creates a CTE->TKG staleness hazard specific to M-RoPE: the CTE
            # cos_cache has shape [3, B, S_cte, dim] and would be reused for
            # every decode step, pinning RoPE at the last prefill position.
            # M-RoPE is position-dependent so we must recompute per-step.
            # XLA fusion absorbs the cost when shapes are static within a NEFF.
            cos_cache, sin_cache = self.rotary_emb(V, position_ids)
            Q, K = apply_multimodal_rotary_pos_emb(
                Q, K, cos_cache, sin_cache, self.mrope_section
            )
        return Q, K, cos_cache, sin_cache


# ---------------------------------------------------------------------------
# Decoder Layer (pre-norm RMSNorm + attn + MLP)
# ---------------------------------------------------------------------------


class NeuronStockmarkTextDecoderLayer(nn.Module):
    def __init__(self, config: InferenceConfig):
        super().__init__()
        self.hidden_size = config.hidden_size
        self.self_attn = NeuronStockmarkTextAttention(config)
        self.mlp = NeuronLlamaMLP(config)
        self.input_layernorm = get_rmsnorm_cls()(
            config.hidden_size, eps=config.rms_norm_eps
        )
        self.post_attention_layernorm = get_rmsnorm_cls()(
            config.hidden_size, eps=config.rms_norm_eps
        )

    def forward(
        self,
        hidden_states: torch.Tensor,
        attention_mask: Optional[torch.Tensor] = None,
        position_ids: Optional[torch.LongTensor] = None,
        past_key_value=None,
        **kwargs,
    ):
        residual = hidden_states
        hidden_states = self.input_layernorm(hidden_states)

        attn_output = self.self_attn(
            hidden_states=hidden_states,
            attention_mask=attention_mask,
            position_ids=position_ids,
            past_key_value=past_key_value,
            **kwargs,
        )
        # NeuronAttentionBase returns an AttentionOutput namedtuple
        hidden_states_sa = attn_output.hidden_states
        hidden_states = residual + hidden_states_sa

        residual = hidden_states
        hidden_states = self.post_attention_layernorm(hidden_states)
        hidden_states = self.mlp(hidden_states)[0]
        hidden_states = residual + hidden_states

        return (
            hidden_states,
            attn_output.present_key_value,
            attn_output.cos_cache,
            attn_output.sin_cache,
            None,
        )


# ---------------------------------------------------------------------------
# Text Model (pure text, no vision scatter)
# ---------------------------------------------------------------------------


class NeuronStockmarkTextModel(NeuronBaseModel):
    def setup_attr_for_model(self, config: InferenceConfig):
        self.on_device_sampling = (
            config.neuron_config.on_device_sampling_config is not None
        )
        self.tp_degree = config.neuron_config.tp_degree
        self.hidden_size = config.hidden_size
        self.num_attention_heads = config.num_attention_heads
        self.num_key_value_heads = config.num_key_value_heads
        self.max_batch_size = config.neuron_config.max_batch_size
        self.buckets = config.neuron_config.buckets

    def init_model(self, config: InferenceConfig):
        self.padding_idx = config.pad_token_id
        self.vocab_size = config.vocab_size

        self.embed_tokens = ParallelEmbedding(
            config.vocab_size,
            config.hidden_size,
            config.pad_token_id,
            dtype=config.neuron_config.torch_dtype,
            shard_across_embedding=True,
            pad=True,
        )
        self.layers = nn.ModuleList(
            [
                NeuronStockmarkTextDecoderLayer(config)
                for _ in range(config.num_hidden_layers)
            ]
        )
        self.norm = get_rmsnorm_cls()(config.hidden_size, eps=config.rms_norm_eps)
        self.lm_head = ColumnParallelLinear(
            config.hidden_size,
            config.vocab_size,
            bias=False,
            pad=True,
            gather_output=not self.on_device_sampling,
            dtype=config.neuron_config.torch_dtype,
        )


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------


class StockmarkTextNeuronConfig(NeuronConfig):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.attn_cls = NeuronStockmarkTextAttention


class StockmarkTextInferenceConfig(InferenceConfig):
    def add_derived_config(self):
        self.num_cores_per_group = 1
        for attr, default in (
            ("output_attentions", False),
            ("output_hidden_states", False),
            ("return_dict", True),
            ("use_cache", False),
            ("tie_word_embeddings", False),
        ):
            if not hasattr(self, attr):
                setattr(self, attr, default)

    def get_required_attributes(self) -> List[str]:
        return [
            "hidden_size",
            "intermediate_size",
            "num_attention_heads",
            "num_hidden_layers",
            "num_key_value_heads",
            "pad_token_id",
            "vocab_size",
            "max_position_embeddings",
            "rope_theta",
            "rms_norm_eps",
            "hidden_act",
        ]

    @classmethod
    def get_neuron_config_cls(cls) -> Type[StockmarkTextNeuronConfig]:
        return StockmarkTextNeuronConfig


# ---------------------------------------------------------------------------
# For-CausalLM wrapper (weight conversion)
# ---------------------------------------------------------------------------


class NeuronStockmarkTextForCausalLM(NeuronBaseForCausalLM):
    """Stockmark-DocReasoner-Qwen2.5-VL-32B text-only NxDI driver.

    Weight layout (HF → NxDI):
      model.embed_tokens.weight       -> embed_tokens.weight
      model.layers.{i}.self_attn.*    -> layers.{i}.self_attn.*
      model.layers.{i}.mlp.*          -> layers.{i}.mlp.*
      model.layers.{i}.input_layernorm.weight -> layers.{i}.input_layernorm.weight
      model.layers.{i}.post_attention_layernorm.weight -> layers.{i}.post_attention_layernorm.weight
      model.norm.weight                -> norm.weight
      lm_head.weight                   -> lm_head.weight
      visual.*                         -> SKIPPED

    TKG / M-RoPE 修正の概要
    -----------------------
    Qwen2.5-VL は M-RoPE (3-axis: temporal/height/width) を使用する。HF の
    prepare_inputs_for_generation は次の処理を行う:

      prefill step (cache_position[0]==0):
        get_rope_index() で [3,B,S] の position_ids を生成し rope_deltas を保存。
        text-only の場合 rope_deltas=0 (各バッチ要素)。

      decode step (cache_position[0]>0):
        position_ids = cache_position[0] + rope_deltas  (値 = L + delta)
        を 3 軸に replicate した [3,B,1] を生成。
        text-only では delta=0 なので position_ids = [[[L]],[[L]],[[L]]]。

    NxDI HuggingFaceGenerationAdapter は常に 2D [B,1] を返し rope_delta を
    加算しない。text-only かつ rope_delta=0 の場合は adapter の値と HF の値が
    一致するため、NeuronStockmarkTextRotaryEmbedding の 2D->3D expand で
    数値的に等価になる。

    もし将来マルチモーダル入力 (画像/動画) を扱う場合、rope_deltas≠0 になり
    adapter の 2D position_ids とHFの 3D position_ids が数値レベルでズレる。
    その場合は下記 prepare_inputs_for_generation オーバーライドで補正する。
    """

    _model_cls = NeuronStockmarkTextModel

    # rope_deltas キャッシュ (prefill 後に保存、decode step で参照)
    # text-only では常に 0 のため現状は実効なし。マルチモーダル時に必要。
    _rope_deltas: Optional[torch.Tensor] = None

    def prepare_inputs_for_generation(self, input_ids, attention_mask=None, **kwargs):
        """NxDI adapter の 2D position_ids に M-RoPE rope_delta を補正する。

        NxDI HuggingFaceGenerationAdapter が返す model_inputs の position_ids は
        2D [B,S]。これを NeuronStockmarkTextRotaryEmbedding が 3 軸 replicate
        するため、text-only (rope_delta=0) では HF と等価。

        診断: TKG step 0 不一致の場合は kv_cache_populated フラグと
        position_ids の値をここでデバッグプリントして確認すること。
        """
        # 親クラス (NeuronBaseForCausalLM) の標準処理に委譲
        model_inputs = super().prepare_inputs_for_generation(
            input_ids, attention_mask=attention_mask, **kwargs
        )

        # --- M-RoPE rope_delta 補正 (将来のマルチモーダル対応) ---
        # text-only では rope_deltas=0 のため補正不要。
        # 画像/動画入力時は以下のコメントを外して有効化する:
        #
        # if self._rope_deltas is not None:
        #     pos = model_inputs.get("position_ids", None)
        #     if pos is not None and pos.dim() == 2:
        #         # kv_cache_populated=True の decode step: pos=[B,1], 値=cache_pos
        #         # HF の値: cache_pos + rope_delta
        #         delta = self._rope_deltas.to(pos.device)  # [B,1]
        #         model_inputs["position_ids"] = pos + delta

        return model_inputs

    # NOTE: previously we overrode forward() to patch position_ids.masked_fill
    # so is_context_encoding would detect left-padded CTE correctly. With
    # padding_side="right" (NxDI native) adapter's own position_ids has min==0
    # and the override is no longer needed. Removing the override also avoids
    # subtle interactions with TKG KV-cache slot mapping.

    @staticmethod
    def load_hf_model(model_path, **kwargs):
        from transformers import Qwen2_5_VLForConditionalGeneration

        return Qwen2_5_VLForConditionalGeneration.from_pretrained(model_path, **kwargs)

    @staticmethod
    def convert_hf_to_neuron_state_dict(
        state_dict: dict, config: InferenceConfig
    ) -> dict:
        neuron_config = config.neuron_config
        num_layers = config.num_hidden_layers
        tp_degree = neuron_config.tp_degree

        new_sd = {}

        for key, value in state_dict.items():
            # Skip vision encoder weights
            if key.startswith("visual."):
                continue
            # Text backbone: strip `model.` prefix
            if key.startswith("model."):
                new_key = key[len("model.") :]
            else:
                new_key = key
            new_sd[new_key] = value.detach().clone() if hasattr(value, "detach") else value

        if neuron_config.fused_qkv:
            for i in range(num_layers):
                prefix = f"layers.{i}.self_attn"
                q_w = new_sd.pop(f"{prefix}.q_proj.weight")
                k_w = new_sd.pop(f"{prefix}.k_proj.weight")
                v_w = new_sd.pop(f"{prefix}.v_proj.weight")
                new_sd[f"{prefix}.qkv_proj.Wqkv.weight"] = torch.cat([q_w, k_w, v_w], dim=0)
                q_b = new_sd.pop(f"{prefix}.q_proj.bias", None)
                k_b = new_sd.pop(f"{prefix}.k_proj.bias", None)
                v_b = new_sd.pop(f"{prefix}.v_proj.bias", None)
                if q_b is not None and k_b is not None and v_b is not None:
                    new_sd[f"{prefix}.qkv_proj.Wqkv.bias"] = torch.cat([q_b, k_b, v_b], dim=0)

        # rank util tensors
        for i in range(num_layers):
            new_sd[f"layers.{i}.self_attn.rank_util.rank"] = torch.arange(
                0, tp_degree, dtype=torch.int32
            )
        if neuron_config.vocab_parallel:
            new_sd["embed_tokens.rank_util.rank"] = torch.arange(
                0, neuron_config.local_ranks_size
            )
        new_sd["rank_util.rank"] = torch.arange(0, tp_degree, dtype=torch.int32)

        gc.collect()
        return new_sd

    @staticmethod
    def update_state_dict_for_tied_weights(state_dict):
        # Stockmark-DocReasoner has tie_word_embeddings=False (explicit lm_head.weight)
        if "lm_head.weight" not in state_dict and "embed_tokens.weight" in state_dict:
            state_dict["lm_head.weight"] = state_dict["embed_tokens.weight"].clone()

    @classmethod
    def get_config_cls(cls):
        return StockmarkTextInferenceConfig

    def get_compiler_args(self):
        lnc = getattr(self.neuron_config, "logical_nc_config", None)
        args = (
            "--enable-saturate-infinity "
            "--enable-mixed-precision-accumulation "
            "--auto-cast=none "
            "--model-type transformer -O1"
        )
        if lnc is not None:
            args += f" --lnc={int(lnc)}"
        args += " --target=trn2"
        return args
