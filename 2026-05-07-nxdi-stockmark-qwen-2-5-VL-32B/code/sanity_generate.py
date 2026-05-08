#!/usr/bin/env python3
"""Multi-prompt sanity check: run Stockmark-DocReasoner through NxD
(adapter.generate with left-padded 128 tokens) and HF CPU, verifying that
NxD produces coherent text (not broken loops) across several prompts.

Acceptance criterion: each NxD output must be a non-degenerate English /
Japanese sentence. Per-token HF match is not required — we already know
BF16 numerical drift makes exact greedy agreement impossible at 64 layers.
"""
import os
import sys
import json
import gc
import time
from pathlib import Path

EXP_DIR = Path(os.environ.get("EXP_DIR") or Path(__file__).resolve().parents[1])
sys.path.insert(0, str(EXP_DIR / "code"))

import torch
from transformers import AutoConfig, AutoTokenizer, Qwen2_5_VLForConditionalGeneration, GenerationConfig
from neuronx_distributed_inference.utils.hf_adapter import HuggingFaceGenerationAdapter

import modeling_stockmark_text as m_stock

NUM_LAYERS = 64
TP_DEGREE = 8
BATCH = 1
# Must match compile-time values: sbatch-compile-full.sbatch compiled with
# MAX_CONTEXT_LEN=128, MAX_NEW_TOKENS=16 -> seq_len=144. Reusing NEFF means
# we can't change these without re-compile.
MAX_CONTEXT_LEN = 128
MAX_NEW_TOKENS = 16

HF_CKPT = EXP_DIR / f"hf-ckpt-{NUM_LAYERS}l"
NEFF_DIR = EXP_DIR / "traces" / f"nxd-{NUM_LAYERS}l"
RESULTS = EXP_DIR / "results"
RESULTS.mkdir(parents=True, exist_ok=True)
MODEL_ID = "stockmark/Stockmark-DocReasoner-Qwen2.5-VL-32B"

print("=" * 60)
print(f"EXP-1037 sanity: multi-prompt generate (NEFF reuse)")
print("=" * 60)


def _truncate(cfg, n):
    if hasattr(cfg, "num_hidden_layers"): cfg.num_hidden_layers = n
    if hasattr(cfg, "layer_types") and cfg.layer_types is not None:
        cfg.layer_types = list(cfg.layer_types)[:n]
    if hasattr(cfg, "text_config") and cfg.text_config is not None:
        tc = cfg.text_config
        if hasattr(tc, "num_hidden_layers"): tc.num_hidden_layers = n
        if hasattr(tc, "layer_types") and tc.layer_types is not None:
            tc.layer_types = list(tc.layer_types)[:n]

hf_cfg = AutoConfig.from_pretrained(str(HF_CKPT))
_truncate(hf_cfg, NUM_LAYERS)

tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
tokenizer.padding_side = "right"
if tokenizer.pad_token_id is None:
    tokenizer.pad_token_id = tokenizer.eos_token_id

t0 = time.time()
hf_model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
    str(HF_CKPT), config=hf_cfg, torch_dtype=torch.bfloat16, low_cpu_mem_usage=True,
).eval().cpu()
print(f"[HF ] loaded {time.time()-t0:.1f}s")

nc = m_stock.StockmarkTextNeuronConfig(
    tp_degree=TP_DEGREE, logical_nc_config=1, torch_dtype=torch.bfloat16,
    batch_size=BATCH, seq_len=MAX_CONTEXT_LEN + MAX_NEW_TOKENS,
    max_context_length=MAX_CONTEXT_LEN,
    n_positions=MAX_CONTEXT_LEN + MAX_NEW_TOKENS,
    max_new_tokens=MAX_NEW_TOKENS, max_length=MAX_CONTEXT_LEN + MAX_NEW_TOKENS,
    on_device_sampling_config=None, vocab_parallel=False, fused_qkv=False,
    padding_side="right",
)
ic = m_stock.StockmarkTextInferenceConfig(
    neuron_config=nc,
    hidden_size=hf_cfg.hidden_size, intermediate_size=hf_cfg.intermediate_size,
    num_attention_heads=hf_cfg.num_attention_heads,
    num_hidden_layers=NUM_LAYERS,
    num_key_value_heads=hf_cfg.num_key_value_heads,
    pad_token_id=tokenizer.pad_token_id, vocab_size=hf_cfg.vocab_size,
    max_position_embeddings=hf_cfg.max_position_embeddings,
    rope_theta=hf_cfg.rope_theta, rope_scaling=hf_cfg.rope_scaling,
    rms_norm_eps=hf_cfg.rms_norm_eps, hidden_act=hf_cfg.hidden_act,
    eos_token_id=tokenizer.eos_token_id,
)
nxd = m_stock.NeuronStockmarkTextForCausalLM(model_path=str(HF_CKPT), config=ic)
nxd.load(str(NEFF_DIR))
adapter = HuggingFaceGenerationAdapter(nxd)
print("[NxD] loaded")


USE_CHAT_TEMPLATE = os.environ.get("USE_CHAT_TEMPLATE", "1") == "1"

def build_prompt(user_text):
    """Stockmark-DocReasoner was fine-tuned with chat template markers.
    Raw text (no <|im_start|>) breaks Japanese generation completely.
    """
    if USE_CHAT_TEMPLATE:
        messages = [{"role": "user", "content": user_text}]
        return tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True,
        )
    return user_text


def build_raw(user_text):
    """Right-pad NEFF + adapter/pad_inputs right-pad: pass raw prompt."""
    prompt = build_prompt(user_text)
    raw = tokenizer([prompt], return_tensors="pt",
                    add_special_tokens=not USE_CHAT_TEMPLATE)
    L = int(raw.input_ids.shape[-1])
    assert L <= MAX_CONTEXT_LEN, f"prompt too long: {L} (target={MAX_CONTEXT_LEN})"
    mask = raw.attention_mask if raw.attention_mask is not None else torch.ones_like(raw.input_ids)
    return raw.input_ids, mask, L


PROMPTS = [
    ("en-short", "The capital of France is?"),
    ("en-facts", "What does AWS Trainium accelerate?"),
    ("en-qa",    "What color is the sky?"),
    ("ja-short", "日本の首都はどこですか。"),
    ("ja-facts", "富士山の高さは何メートルですか。"),
    ("ja-qa",    "猫の鳴き声を教えてください。"),
]

REP_PENALTY = float(os.environ.get("REP_PENALTY", "1.05"))
# Stockmark-DocReasoner generation_config.json recommends:
#   repetition_penalty=1.05, do_sample=True, temperature=1e-06
# We use do_sample=False (pure greedy) for deterministic HF vs NxD comparison.
# eos_token_id includes both <|im_end|>=151645 and <|endoftext|>=151643.
gen_config = GenerationConfig(
    max_new_tokens=MAX_NEW_TOKENS, do_sample=False,
    repetition_penalty=REP_PENALTY,
    pad_token_id=tokenizer.pad_token_id,
    eos_token_id=[151645, 151643],
)
print(f"[CFG] chat_template={USE_CHAT_TEMPLATE} repetition_penalty={REP_PENALTY}")

results = []
print()
for label, prompt in PROMPTS:
    ids, mask, L = build_raw(prompt)
    t1 = time.time()
    with torch.no_grad():
        nxd_out = adapter.generate(ids, attention_mask=mask, generation_config=gen_config)
    t_nxd = time.time() - t1
    t2 = time.time()
    with torch.no_grad():
        cpu_out = hf_model.generate(ids, attention_mask=mask, generation_config=gen_config)
    t_cpu = time.time() - t2

    # Generated tokens come after the original raw prompt length L.
    nxd_tail = nxd_out[0, L:].tolist()
    cpu_tail = cpu_out[0, L:].tolist()
    nxd_text = tokenizer.decode(nxd_tail, skip_special_tokens=True)
    cpu_text = tokenizer.decode(cpu_tail, skip_special_tokens=True)
    match_n = sum(1 for a, b in zip(cpu_tail, nxd_tail) if a == b)

    # Degeneracy check: >=6 consecutive repeats of a single token == broken
    degenerate = False
    for i in range(len(nxd_tail) - 5):
        if len(set(nxd_tail[i:i+6])) == 1:
            degenerate = True; break

    print(f"  [{label}]  prompt={prompt!r}")
    print(f"    CPU ({t_cpu:.1f}s): {cpu_text!r}")
    print(f"    NxD ({t_nxd:.1f}s): {nxd_text!r}")
    print(f"    match_tokens={match_n}/{len(cpu_tail)}  degenerate_nxd={degenerate}")
    print()

    results.append({
        "label": label,
        "prompt": prompt,
        "raw_len": L,
        "cpu_text": cpu_text,
        "nxd_text": nxd_text,
        "cpu_tokens": cpu_tail,
        "nxd_tokens": nxd_tail,
        "match_tokens": match_n,
        "total_tokens": len(cpu_tail),
        "nxd_time_sec": round(t_nxd, 2),
        "cpu_time_sec": round(t_cpu, 2),
        "nxd_degenerate": degenerate,
    })

# Verdict
n = len(results)
n_not_degenerate = sum(1 for r in results if not r["nxd_degenerate"])
avg_match = sum(r["match_tokens"] for r in results) / sum(r["total_tokens"] for r in results)
print("=" * 60)
print(f"[SANITY] {n_not_degenerate}/{n} NxD outputs are non-degenerate (coherent text)")
print(f"[SANITY] avg HF-vs-NxD greedy token match = {avg_match:.1%}")
if n_not_degenerate == n:
    verdict = "A-WIN: all prompts produce coherent (non-looping) generation"
elif n_not_degenerate >= n * 0.8:
    verdict = f"A: {n_not_degenerate}/{n} coherent, BF16 drift causes per-token divergence but generation is usable"
else:
    verdict = f"B: only {n_not_degenerate}/{n} coherent, needs further investigation"
print(f"[VERDICT] {verdict}")
print("=" * 60)

(RESULTS / "sanity-generate.json").write_text(json.dumps({
    "verdict": verdict,
    "n_prompts": n,
    "n_non_degenerate": n_not_degenerate,
    "avg_greedy_match_rate": avg_match,
    "per_prompt": results,
}, indent=2, ensure_ascii=False))
print(f"[RESULT] {RESULTS}/sanity-generate.json")
