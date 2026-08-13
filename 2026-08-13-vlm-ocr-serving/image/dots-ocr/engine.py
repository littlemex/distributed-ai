"""dots.ocr engine: a document VLM that returns layout blocks with bbox + text.

dots.ocr (rednote-hilab/dots.ocr, ~3B, MIT) parses a page into layout elements, each with
a pixel bbox, a category, and its text. It is the VLM representative among the channels:
strong on structured documents, but -- like every VLM reader -- it emits no per-element
confidence, so tokens report confidence=null (the harness/contract keeps that honest rather
than fabricating 1.0).

Each layout element becomes one token: text = the element's text, bbox = the element's
[x0, y0, x1, y1] in image pixels, polygon/confidence = null. The category is folded into
neither field (the contract is text+box+score); a later revision can carry it if a consumer
needs it.
"""

from __future__ import annotations

import json
import os
import re
from typing import List

import torch
from PIL import Image

from common.extract_contract import Token, make_token

ENGINE_KEY = "dots-ocr"

_MODEL_ID = os.environ.get("DOTS_MODEL_ID", "rednote-hilab/dots.ocr")
_MAX_NEW_TOKENS = int(os.environ.get("DOTS_MAX_NEW_TOKENS", "8192"))

# The layout+text prompt: return a JSON list of {bbox, category, text}, one per element.
_PROMPT = (
    "Please output the layout information from this image, including each layout element's "
    "bbox, its category, and the corresponding text content within the bbox. Return ONLY a "
    "JSON list; each item is an object with keys: bbox ([x0, y0, x1, y1] in pixels), category, "
    "and text."
)

_model = None
_processor = None


def version() -> str:
    return f"dots.ocr ({_MODEL_ID})"


def load() -> None:
    global _model, _processor
    from transformers import AutoModelForCausalLM, AutoProcessor

    dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32
    # flash_attention_2 when a GPU is present; SDPA otherwise so a CPU smoke still loads.
    attn = "flash_attention_2" if torch.cuda.is_available() else "sdpa"
    try:
        _model = AutoModelForCausalLM.from_pretrained(
            _MODEL_ID,
            torch_dtype=dtype,
            attn_implementation=attn,
            device_map="auto",
            trust_remote_code=True,
        )
    except Exception:
        # flash-attn may be unavailable in the built image; retry with SDPA.
        _model = AutoModelForCausalLM.from_pretrained(
            _MODEL_ID,
            torch_dtype=dtype,
            attn_implementation="sdpa",
            device_map="auto",
            trust_remote_code=True,
        )
    _processor = AutoProcessor.from_pretrained(_MODEL_ID, trust_remote_code=True)
    _model.eval()


def _generate(image: Image.Image) -> str:
    messages = [
        {
            "role": "user",
            "content": [
                {"type": "image", "image": image},
                {"type": "text", "text": _PROMPT},
            ],
        }
    ]
    text = _processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    # qwen_vl_utils extracts the PIL image(s) from the messages for the processor.
    from qwen_vl_utils import process_vision_info

    image_inputs, video_inputs = process_vision_info(messages)
    inputs = _processor(
        text=[text], images=image_inputs, videos=video_inputs, padding=True, return_tensors="pt"
    ).to(_model.device)
    with torch.inference_mode():
        generated = _model.generate(**inputs, max_new_tokens=_MAX_NEW_TOKENS, do_sample=False)
    # Strip the prompt tokens, decode only the completion.
    trimmed = [out[len(inp):] for inp, out in zip(inputs.input_ids, generated)]
    return _processor.batch_decode(
        trimmed, skip_special_tokens=True, clean_up_tokenization_spaces=False
    )[0]


def _parse(out: str) -> list:
    """Best-effort: pull the first JSON array out of the model text, tolerating fences/prose."""
    fence = re.search(r"```(?:json)?\s*(\[.*?\])\s*```", out, re.DOTALL)
    candidate = fence.group(1) if fence else None
    if candidate is None:
        start, end = out.find("["), out.rfind("]")
        candidate = out[start : end + 1] if (start != -1 and end > start) else None
    if candidate is None:
        return []
    try:
        parsed = json.loads(candidate)
        return parsed if isinstance(parsed, list) else []
    except json.JSONDecodeError:
        return []


def extract(image: Image.Image) -> List[Token]:
    w, h = image.size
    elements = _parse(_generate(image))
    tokens: List[Token] = []
    for el in elements:
        if not isinstance(el, dict):
            continue
        text = (el.get("text") or "").strip()
        bbox = el.get("bbox")
        if not text or not isinstance(bbox, (list, tuple)) or len(bbox) != 4:
            continue
        try:
            box = [float(v) for v in bbox]
        except (TypeError, ValueError):
            continue
        # dots.ocr emits no per-element score -> confidence stays null per the contract.
        tokens.append(make_token(text, box, w, h, confidence=None))
    return tokens
