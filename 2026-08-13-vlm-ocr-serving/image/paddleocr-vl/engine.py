"""PaddleOCR engine: PP-OCR detection + recognition, quad boxes + per-line confidence.

Serves the classic PaddleOCR pipeline (text detection -> angle -> recognition). It returns
a rotated quad per text line plus a recognition score, which maps cleanly onto the token
contract (polygon = the quad, bbox = its axis-aligned envelope, confidence = the score).

Naming: the project calls this channel "paddleocr". The PaddleOCR-VL 0.9B VLM can be
swapped in later behind the same /extract contract by changing this module + the image's
deps; the wire format does not change.

Robustness: PaddleOCR's return shape changed across 2.x/3.x. This handles both the 3.x
predict() dict (rec_texts / rec_scores / rec_polys|dt_polys) and the 2.x ocr() nested
list ([[ [quad, (text, score)], ... ]]), so a minor version bump does not silently return
zero tokens (the exact failure the pilot hit).
"""

from __future__ import annotations

import os
from typing import List

import numpy as np
from PIL import Image

from common.extract_contract import Token, make_token, polygon_to_bbox

ENGINE_KEY = "paddleocr"

_LANG = os.environ.get("PADDLE_LANG", "en")
_ocr = None


def version() -> str:
    try:
        import paddleocr

        return f"paddleocr {paddleocr.__version__} (lang={_LANG})"
    except Exception:
        return f"paddleocr (lang={_LANG})"


def load() -> None:
    global _ocr
    from paddleocr import PaddleOCR

    # GPU is auto-detected by the installed paddlepaddle-gpu build; models are baked into the
    # image at build time. PaddleOCR 3.x takes lang + sensible defaults (angle handled
    # internally); the 2.x constructor (use_angle_cls/show_log) is a fallback for older pins.
    try:
        _ocr = PaddleOCR(lang=_LANG)
    except TypeError:
        _ocr = PaddleOCR(use_angle_cls=True, lang=_LANG, show_log=False)


def _to_bgr(image: Image.Image) -> np.ndarray:
    # PaddleOCR treats an ndarray as BGR (its cv2 heritage); PIL gives RGB, so flip.
    return np.asarray(image)[:, :, ::-1].copy()


def _tokens_from_3x(result, w: int, h: int) -> List[Token]:
    """3.x predict(): a list of per-image result objects that behave like dicts with
    parallel arrays rec_texts / rec_scores / (rec_polys|dt_polys)."""
    tokens: List[Token] = []
    for page in result:
        d = page.get("res", page) if hasattr(page, "get") else getattr(page, "res", page)
        texts = d.get("rec_texts") or []
        scores = d.get("rec_scores") or []
        polys = d.get("rec_polys")
        if polys is None:
            polys = d.get("dt_polys") or []
        for i, text in enumerate(texts):
            text = (text or "").strip()
            if not text:
                continue
            poly = [[float(x), float(y)] for x, y in np.asarray(polys[i]).tolist()]
            score = float(scores[i]) if i < len(scores) else None
            tokens.append(
                make_token(text, polygon_to_bbox(poly), w, h, confidence=score, polygon=poly)
            )
    return tokens


def _tokens_from_2x(result, w: int, h: int) -> List[Token]:
    """2.x ocr(): [[ [quad, (text, score)], ... ]] (outer list is per image)."""
    tokens: List[Token] = []
    pages = result if result else []
    for page in pages:
        if not page:
            continue
        for line in page:
            quad, (text, score) = line[0], line[1]
            text = (text or "").strip()
            if not text:
                continue
            poly = [[float(x), float(y)] for x, y in quad]
            tokens.append(
                make_token(
                    text, polygon_to_bbox(poly), w, h, confidence=float(score), polygon=poly
                )
            )
    return tokens


def extract(image: Image.Image) -> List[Token]:
    w, h = image.size
    img = _to_bgr(image)
    # Prefer the 3.x predict() API; fall back to the 2.x ocr() API.
    if hasattr(_ocr, "predict"):
        try:
            return _tokens_from_3x(_ocr.predict(img), w, h)
        except Exception:
            pass
    result = _ocr.ocr(img, cls=True)
    return _tokens_from_2x(result, w, h)
