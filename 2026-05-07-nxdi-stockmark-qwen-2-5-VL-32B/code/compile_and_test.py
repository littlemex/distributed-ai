#!/usr/bin/env python3
"""EXP-1037 (B): Stockmark-DocReasoner-Qwen2.5-VL-32B text-only NxD compile + cos + generate.

Fixes after verify_stockmark.py revealed padding handling bugs (cos=0.51 on
real prompts, greedy diverges to <|endoftext|>):

  1. NeuronConfig must set padding_side="left" so the CTE NEFF honors
     attention_mask (the default "right" path drops padding info).
  2. Inputs are left-padded (pad first, real tokens last) both for the
     cos probe and for HuggingFaceGenerationAdapter.generate().
  3. n_positions / max_length include room for max_new_tokens (TKG needs
     the KV cache space).
  4. Generation goes through HuggingFaceGenerationAdapter (CTE->TKG
     switching + reset + prepare_inputs_for_generation handled for us).

Flow:
  1. Snapshot HF Qwen2.5-VL at NUM_LAYERS (1 or 64)
  2. CPU reference: left-padded input + attention_mask, keep logits at
     the last *real* position
  3. Compile NeuronStockmarkTextForCausalLM with padding_side="left"
  4. cos probe on the same left-padded input
  5. Greedy generate through HuggingFaceGenerationAdapter, compare
     against HF .generate() on CPU
"""
import os
import sys
import gc
import json
import time
import traceback
from pathlib import Path

EXP_DIR = Path(os.environ.get("EXP_DIR") or Path(__file__).resolve().parents[1])
sys.path.insert(0, str(EXP_DIR / "code"))

import torch
import torch.nn.functional as F

MODEL_ID = "stockmark/Stockmark-DocReasoner-Qwen2.5-VL-32B"
BATCH = 1
NUM_LAYERS = int(os.environ.get("NUM_LAYERS", 1))
TP_DEGREE = 8
HF_TOKEN = os.environ.get("HF_TOKEN")

# Context length (max prompt tokens) and generation length.
# seq_len = max_context_length + max_new_tokens so KV cache has room for TKG.
MAX_CONTEXT_LEN = int(os.environ.get("MAX_CONTEXT_LEN", 128))
MAX_NEW_TOKENS = int(os.environ.get("MAX_NEW_TOKENS", 16))
SEQ_LEN = MAX_CONTEXT_LEN + MAX_NEW_TOKENS

# Multi-bucket mode: buckets for CTE are built automatically for a few
# context lengths so that short prompts go through a smaller NEFF.
MULTI_BUCKET = os.environ.get("MULTI_BUCKET", "0") == "1"
CTE_BUCKETS = (
    [32, 64, 96, MAX_CONTEXT_LEN] if MULTI_BUCKET else None
)

RESULTS = EXP_DIR / "results"
NEFF_DIR = EXP_DIR / "traces" / f"nxd-{NUM_LAYERS}l"
HF_CKPT_DIR = EXP_DIR / f"hf-ckpt-{NUM_LAYERS}l"
RESULTS.mkdir(parents=True, exist_ok=True)
NEFF_DIR.mkdir(parents=True, exist_ok=True)
HF_CKPT_DIR.mkdir(parents=True, exist_ok=True)

print("=" * 60)
print(f"EXP-1037 (B): Stockmark-DocReasoner-Qwen2.5-VL-32B NxD {NUM_LAYERS}-layer")
print(f"  max_context={MAX_CONTEXT_LEN} max_new={MAX_NEW_TOKENS} seq_len={SEQ_LEN}")
print("=" * 60)

import modeling_stockmark_text as m_stock
print(f"[IMPORT] modeling_stockmark_text from {m_stock.__file__}")

from transformers import AutoConfig, AutoTokenizer, Qwen2_5_VLForConditionalGeneration


def _truncate_layers(cfg, n):
    if hasattr(cfg, "num_hidden_layers"):
        cfg.num_hidden_layers = n
    if hasattr(cfg, "layer_types") and cfg.layer_types is not None:
        cfg.layer_types = list(cfg.layer_types)[:n]
    if hasattr(cfg, "text_config") and cfg.text_config is not None:
        tc = cfg.text_config
        if hasattr(tc, "num_hidden_layers"):
            tc.num_hidden_layers = n
        if hasattr(tc, "layer_types") and tc.layer_types is not None:
            tc.layer_types = list(tc.layer_types)[:n]
    return cfg


# ---------------------------------------------------------------------------
# Step 1: HF snapshot (truncated to NUM_LAYERS)
# ---------------------------------------------------------------------------
if not (HF_CKPT_DIR / "config.json").exists():
    print(f"[HF ] loading + truncating num_hidden_layers to {NUM_LAYERS}")
    t0 = time.time()
    hf_config = AutoConfig.from_pretrained(MODEL_ID, token=HF_TOKEN)
    _truncate_layers(hf_config, NUM_LAYERS)
    hf_model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
        MODEL_ID, config=hf_config, torch_dtype=torch.bfloat16,
        low_cpu_mem_usage=True, token=HF_TOKEN,
    ).eval().cpu()
    hf_model.save_pretrained(str(HF_CKPT_DIR), safe_serialization=True)

    import json as _json
    cfg_path = HF_CKPT_DIR / "config.json"
    cfg_dict = _json.loads(cfg_path.read_text())
    def _truncate_dict(d, n):
        if "num_hidden_layers" in d:
            d["num_hidden_layers"] = n
        if "layer_types" in d and isinstance(d["layer_types"], list):
            d["layer_types"] = d["layer_types"][:n]
    _truncate_dict(cfg_dict, NUM_LAYERS)
    if "text_config" in cfg_dict and isinstance(cfg_dict["text_config"], dict):
        _truncate_dict(cfg_dict["text_config"], NUM_LAYERS)
    cfg_path.write_text(_json.dumps(cfg_dict, indent=2))
    print(f"[HF ] saved + re-truncated config to {HF_CKPT_DIR} {time.time()-t0:.1f}s")
else:
    print(f"[HF ] ckpt already exists at {HF_CKPT_DIR}, reuse")

hf_config = AutoConfig.from_pretrained(str(HF_CKPT_DIR))
_truncate_layers(hf_config, NUM_LAYERS)

tokenizer = AutoTokenizer.from_pretrained(MODEL_ID, token=HF_TOKEN)
if tokenizer.pad_token_id is None:
    tokenizer.pad_token_id = tokenizer.eos_token_id
tokenizer.padding_side = "right"
print(f"[TOK] vocab={tokenizer.vocab_size} pad_id={tokenizer.pad_token_id} eos_id={tokenizer.eos_token_id}")

hf_model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
    str(HF_CKPT_DIR), config=hf_config, torch_dtype=torch.bfloat16, low_cpu_mem_usage=True,
).eval().cpu()

print(f"[cfg] hidden={hf_config.hidden_size} heads={hf_config.num_attention_heads} "
      f"kv_heads={hf_config.num_key_value_heads} layers={hf_config.num_hidden_layers} "
      f"rope={hf_config.rope_theta}")

# ---------------------------------------------------------------------------
# Step 2: CPU reference (left-padded input, probe last real token)
# ---------------------------------------------------------------------------
PROBE_PROMPT = os.environ.get("PROBE_PROMPT", "Trainium is an AWS chip that accelerates")
probe = tokenizer([PROBE_PROMPT], return_tensors="pt", add_special_tokens=True)
raw_len = int(probe.input_ids.shape[-1])
assert raw_len <= MAX_CONTEXT_LEN, f"prompt too long ({raw_len} > {MAX_CONTEXT_LEN})"

# Right-pad to MAX_CONTEXT_LEN to match neuron_config.padding_side="right" and
# NxDI's pad_inputs() which always right-pads.
pad_len = MAX_CONTEXT_LEN - raw_len
probe_ids = torch.cat([
    probe.input_ids,
    torch.full((BATCH, pad_len), tokenizer.pad_token_id, dtype=torch.long),
], dim=-1)
probe_mask = torch.cat([
    torch.ones(BATCH, raw_len, dtype=torch.long),
    torch.zeros(BATCH, pad_len, dtype=torch.long),
], dim=-1)

print(f"[PROBE] prompt={PROBE_PROMPT!r} raw_len={raw_len} pad_len={pad_len}")
print(f"[CPU] HF Qwen2.5-VL reference forward (right-pad text) ...")
t1 = time.time()
with torch.no_grad():
    out_cpu = hf_model(
        input_ids=probe_ids, attention_mask=probe_mask,
        pixel_values=None, use_cache=False, return_dict=True,
    )
    y_cpu = out_cpu.logits
print(f"[CPU] done {time.time()-t1:.1f}s shape={tuple(y_cpu.shape)}")


# ---------------------------------------------------------------------------
# Step 3: NxD InferenceConfig (padding_side="left", max_length includes TKG)
# ---------------------------------------------------------------------------
print("[NxD] building StockmarkTextInferenceConfig...")
neuron_config_kwargs = dict(
    tp_degree=TP_DEGREE,
    logical_nc_config=1,
    torch_dtype=torch.bfloat16,
    batch_size=BATCH,
    seq_len=SEQ_LEN,
    max_context_length=MAX_CONTEXT_LEN,
    n_positions=SEQ_LEN,
    max_new_tokens=MAX_NEW_TOKENS,
    max_length=SEQ_LEN,
    on_device_sampling_config=None,
    vocab_parallel=False,
    fused_qkv=False,
    # Match NxDI's pad_inputs() behavior which always right-pads. Running
    # padding_side="left" against right-padded inputs (from adapter) was
    # the root cause of TKG destruction for Japanese.
    padding_side="right",
)
if CTE_BUCKETS is not None:
    neuron_config_kwargs["buckets"] = CTE_BUCKETS
    print(f"[NxD] multi-bucket CTE: {CTE_BUCKETS}")
neuron_config = m_stock.StockmarkTextNeuronConfig(**neuron_config_kwargs)

inf_config = m_stock.StockmarkTextInferenceConfig(
    neuron_config=neuron_config,
    hidden_size=hf_config.hidden_size,
    intermediate_size=hf_config.intermediate_size,
    num_attention_heads=hf_config.num_attention_heads,
    num_hidden_layers=NUM_LAYERS,
    num_key_value_heads=hf_config.num_key_value_heads,
    pad_token_id=tokenizer.pad_token_id,
    vocab_size=hf_config.vocab_size,
    max_position_embeddings=hf_config.max_position_embeddings,
    rope_theta=hf_config.rope_theta,
    rope_scaling=hf_config.rope_scaling,
    rms_norm_eps=hf_config.rms_norm_eps,
    hidden_act=hf_config.hidden_act,
    eos_token_id=tokenizer.eos_token_id,
)
print(f"[NxD] config: hidden={inf_config.hidden_size} heads={inf_config.num_attention_heads} "
      f"kv_heads={inf_config.num_key_value_heads} layers={inf_config.num_hidden_layers}")


# ---------------------------------------------------------------------------
# Step 4: Compile + Load
# ---------------------------------------------------------------------------
compiled_path = str(NEFF_DIR)

try:
    nxd_model = m_stock.NeuronStockmarkTextForCausalLM(
        model_path=str(HF_CKPT_DIR), config=inf_config,
    )
    print(f"[NxD] constructed, models count={len(nxd_model.models)}")
    for mdl in nxd_model.models:
        print(f"  - tag={mdl.tag} batch={mdl.neuron_config.batch_size} "
              f"n_active={mdl.neuron_config.n_active_tokens} "
              f"pad_side={mdl.neuron_config.padding_side}")
except Exception as e:
    print(f"[NxD] construction FAILED: {type(e).__name__}: {e}")
    traceback.print_exc(limit=20)
    (RESULTS / f"metrics-{NUM_LAYERS}l.json").write_text(json.dumps({
        "status": "construction_fail", "error": f"{type(e).__name__}: {e}",
    }, indent=2))
    sys.exit(1)

SKIP_COMPILE = os.environ.get("SKIP_COMPILE", "0") == "1" or (NEFF_DIR / "model.pt").exists()
if SKIP_COMPILE:
    print(f"[NxD] compile SKIPPED (NEFF at {compiled_path}/model.pt exists, reuse)")
    t_compile = 0.0
else:
    print(f"[NxD] compile -> {compiled_path}")
    t2 = time.time()
    try:
        nxd_model.compile(compiled_path)
        t_compile = time.time() - t2
        print(f"[NxD] compile PASS {t_compile:.1f}s ({t_compile/60:.2f} min)")
    except Exception as e:
        print(f"[NxD] compile FAILED: {type(e).__name__}: {e}")
        traceback.print_exc(limit=25)
        (RESULTS / f"metrics-{NUM_LAYERS}l.json").write_text(json.dumps({
            "status": "compile_fail", "error": f"{type(e).__name__}: {e}",
        }, indent=2))
        sys.exit(2)

print(f"[NxD] load + load_weights ...")
t3 = time.time()
try:
    nxd_model.load(compiled_path)
    print(f"[NxD] load PASS {time.time()-t3:.1f}s")
except Exception as e:
    print(f"[NxD] load FAILED: {type(e).__name__}: {e}")
    traceback.print_exc(limit=20)
    sys.exit(3)


# ---------------------------------------------------------------------------
# Step 5: cos probe on the left-padded input
# ---------------------------------------------------------------------------
print("[NxD] cos probe forward (left-pad, attention_mask respected) ...")

# With padding_side="left", position_ids should be 0 over pads, then
# ascending 0..raw_len-1 starting at the first real token. The cleanest
# source is attention_mask.long().cumsum(-1) - 1, clamped.
def build_position_ids(mask):
    pos = mask.long().cumsum(dim=-1) - 1
    return pos.clamp(min=0)

probe_pos = build_position_ids(probe_mask)
probe_seq = torch.arange(BATCH, dtype=torch.long)

t4 = time.time()
with torch.no_grad():
    out = nxd_model(
        input_ids=probe_ids, attention_mask=probe_mask,
        position_ids=probe_pos, seq_ids=probe_seq,
    )
print(f"[NxD] probe forward {time.time()-t4:.2f}s")

y_nxd = out.logits if hasattr(out, "logits") else (out[0] if isinstance(out, (tuple, list)) else out)
# CPU logit at the last real token index (MAX_CONTEXT_LEN - 1 for left-pad);
# NxD returns last-active-token logits.
# With right-pad the last real token sits at position (raw_len - 1), not -1.
# CPU logits at that position vs NxD's "last active token" logit.
y_cpu_last = y_cpu[:, raw_len - 1, :].float().flatten()
y_nxd_last = (y_nxd[:, -1, :] if y_nxd.dim() == 3 else y_nxd).float().flatten()
n = min(y_cpu_last.shape[0], y_nxd_last.shape[0])
probe_cos = F.cosine_similarity(
    y_cpu_last[:n].unsqueeze(0), y_nxd_last[:n].unsqueeze(0),
).item()
probe_top_cpu = int(y_cpu_last[:n].argmax().item())
probe_top_nxd = int(y_nxd_last[:n].argmax().item())
print(f"[PROBE] cos={probe_cos:.6f}  "
      f"top1 CPU={probe_top_cpu} ({tokenizer.decode([probe_top_cpu])!r}) "
      f"vs NxD={probe_top_nxd} ({tokenizer.decode([probe_top_nxd])!r})")


# ---------------------------------------------------------------------------
# Step 6: Greedy generate via HuggingFaceGenerationAdapter
# ---------------------------------------------------------------------------
print("[GEN] generating via HuggingFaceGenerationAdapter ...")
from transformers import GenerationConfig
from neuronx_distributed_inference.utils.hf_adapter import HuggingFaceGenerationAdapter

adapter = HuggingFaceGenerationAdapter(nxd_model)

# Right-pad NEFF + right-padding adapter/pad_inputs: pass raw prompt,
# let the adapter pad. No manual pre-padding.
gen_raw = tokenizer([PROBE_PROMPT], return_tensors="pt", add_special_tokens=True)
gen_input_ids = gen_raw.input_ids
gen_attention_mask = gen_raw.attention_mask if gen_raw.attention_mask is not None else torch.ones_like(gen_input_ids)
_raw_len = int(gen_input_ids.shape[-1])
print(f"[GEN] raw prompt len={_raw_len} (adapter/pad_inputs will right-pad to {MAX_CONTEXT_LEN})")

gen_config = GenerationConfig(
    max_new_tokens=MAX_NEW_TOKENS,
    do_sample=False,
    pad_token_id=tokenizer.pad_token_id,
    eos_token_id=tokenizer.eos_token_id,
)

t5 = time.time()
with torch.no_grad():
    nxd_out_ids = adapter.generate(
        gen_input_ids,
        attention_mask=gen_attention_mask,
        generation_config=gen_config,
    )
print(f"[GEN] NxD generate done {time.time()-t5:.1f}s")

# Compare against HF greedy on CPU with the SAME left-padded input.
t6 = time.time()
with torch.no_grad():
    cpu_out_ids = hf_model.generate(
        gen_input_ids,
        attention_mask=gen_attention_mask,
        generation_config=gen_config,
    )
print(f"[GEN] CPU generate done {time.time()-t6:.1f}s")

# Generated tokens come after the original raw prompt length.
nxd_tail = nxd_out_ids[0, _raw_len:].tolist()
cpu_tail = cpu_out_ids[0, _raw_len:].tolist()
match_n = sum(1 for a, b in zip(cpu_tail, nxd_tail) if a == b)

nxd_text = tokenizer.decode(nxd_out_ids[0], skip_special_tokens=True)
cpu_text = tokenizer.decode(cpu_out_ids[0], skip_special_tokens=True)
print("=" * 60)
print(f"[GEN] CPU: {cpu_text!r}")
print(f"[GEN] NxD: {nxd_text!r}")
print(f"[GEN] token match: {match_n}/{len(cpu_tail)}")
print("=" * 60)


# ---------------------------------------------------------------------------
# Step 7: metrics + verdict
# ---------------------------------------------------------------------------
metrics = {
    "exp_id": "EXP-1037-B",
    "model": MODEL_ID,
    "num_layers": NUM_LAYERS,
    "tp_degree": TP_DEGREE,
    "max_context_len": MAX_CONTEXT_LEN,
    "max_new_tokens": MAX_NEW_TOKENS,
    "seq_len": SEQ_LEN,
    "dtype": "bfloat16",
    "padding_side": "left",
    "compile_time_sec": round(t_compile, 2),
    "probe_prompt": PROBE_PROMPT,
    "probe_cos": probe_cos,
    "probe_top1_cpu": probe_top_cpu,
    "probe_top1_nxd": probe_top_nxd,
    "probe_top1_match": 1 if probe_top_cpu == probe_top_nxd else 0,
    "gen_cpu_tokens": cpu_tail,
    "gen_nxd_tokens": nxd_tail,
    "gen_token_match": match_n,
    "gen_token_total": len(cpu_tail),
    "gen_cpu_text": cpu_text,
    "gen_nxd_text": nxd_text,
}
if probe_cos > 0.99 and match_n == len(cpu_tail):
    metrics["verdict"] = "A-WIN: probe cos>0.99 + greedy exact match"
elif probe_cos > 0.95 and match_n >= 0.8 * len(cpu_tail):
    metrics["verdict"] = "A: mostly aligned (probe cos + >=80% greedy match)"
elif probe_cos > 0.5:
    metrics["verdict"] = "B: partial alignment, needs further fix"
else:
    metrics["verdict"] = f"D: cos={probe_cos:.4f} diverges"

(RESULTS / f"metrics-{NUM_LAYERS}l.json").write_text(
    json.dumps(metrics, indent=2, ensure_ascii=False)
)
print(f"[METRICS] {RESULTS}/metrics-{NUM_LAYERS}l.json")
print(f"[VERDICT] {metrics['verdict']}")
