"""Tesseract engine: classic CPU OCR, word-level boxes + per-word confidence.

Tesseract is the deliberately-independent channel. Every VLM-based reader shares the
same failure modes (they correlated at phi ~= 0.57 in the pilot), so a purely classical
CV/heuristic OCR whose errors are uncorrelated with a VLM's is worth more to a verifier
than a second VLM. It also emits a real per-word confidence, which the VLM readers do
not, so it anchors the selective-verification signal.
"""

from __future__ import annotations

from typing import List

import pytesseract
from PIL import Image

from common.extract_contract import Token, make_token

ENGINE_KEY = "tesseract"

# --oem 1  = LSTM engine only (the neural line recognizer, best accuracy).
# --psm 11 = "sparse text": find as much text as possible in no particular order, which
#            suits receipts/forms whose layout is not a single uniform block.
_CONFIG = "--oem 1 --psm 11"
_LANG = "eng"


def version() -> str:
    return f"tesseract {pytesseract.get_tesseract_version()} (lang={_LANG}, {_CONFIG})"


def load() -> None:
    # No model to warm; probe the binary so /readyz only flips true if tesseract is usable.
    pytesseract.get_tesseract_version()


def extract(image: Image.Image) -> List[Token]:
    w, h = image.size
    data = pytesseract.image_to_data(
        image, lang=_LANG, config=_CONFIG, output_type=pytesseract.Output.DICT
    )
    tokens: List[Token] = []
    n = len(data["text"])
    for i in range(n):
        text = (data["text"][i] or "").strip()
        if not text:
            continue
        # conf is a string "0".."100", or "-1" for a non-text region. Drop the -1 rows.
        try:
            conf = float(data["conf"][i])
        except (TypeError, ValueError):
            conf = -1.0
        if conf < 0:
            continue
        x, y, bw, bh = (
            data["left"][i],
            data["top"][i],
            data["width"][i],
            data["height"][i],
        )
        tokens.append(
            make_token(
                text=text,
                bbox=[x, y, x + bw, y + bh],
                width=w,
                height=h,
                confidence=conf / 100.0,  # 0..100 -> 0..1 to match the contract
            )
        )
    return tokens
