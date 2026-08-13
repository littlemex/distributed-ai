"""Unified /extract response contract, shared by every OCR/doc-VLM serving image.

Every engine in this project (paddleocr, dots-ocr, tesseract) speaks the SAME wire
format so a verifier can treat them as interchangeable, independent evidence channels
and compare them token-for-token. The contract is deliberately about GROUNDED TOKENS
(text + where it is on the page + how sure the engine is), not about parsed fields:
field-value localization (keyword -> nearest value box, SICM-style) is a client-side
concern layered on top of these tokens, so the servers stay engine-focused and every
channel exposes the exact same primitive.

Coordinate convention (fixed for ALL engines, documented once here):
  * bbox is [x0, y0, x1, y1] in ABSOLUTE PIXELS, origin at the TOP-LEFT of the image,
    x to the right, y downward. x0<=x1, y0<=y1 (an axis-aligned box).
  * bbox_norm is the same box divided by (width, height) -> each value in [0, 1], so a
    consumer can compare boxes across engines even if one downscaled the image.
  * polygon (optional) is the raw, possibly-rotated quad the engine returned, as
    [[x, y], ...] in absolute pixels. bbox is polygon's axis-aligned envelope. Engines
    that only give an axis-aligned box (e.g. Tesseract) omit polygon.
  * confidence is in [0, 1]. Engines that do not emit a per-token score report null
    (NOT a fabricated 1.0) so a consumer can tell "the engine is sure" apart from "the
    engine has no opinion" -- that distinction is exactly what selective verification
    keys on.
"""

from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel, Field


class ImageSize(BaseModel):
    width: int = Field(..., description="Image width in pixels the boxes are relative to.")
    height: int = Field(..., description="Image height in pixels the boxes are relative to.")


class Token(BaseModel):
    """One grounded piece of text: what was read, where, and how sure the engine is."""

    text: str = Field(..., description="The recognized text for this region.")
    bbox: List[float] = Field(
        ...,
        min_length=4,
        max_length=4,
        description="[x0, y0, x1, y1] axis-aligned box in absolute pixels, top-left origin.",
    )
    bbox_norm: List[float] = Field(
        ...,
        min_length=4,
        max_length=4,
        description="bbox divided by (w, h, w, h); each value in [0, 1].",
    )
    confidence: Optional[float] = Field(
        None, description="Per-token score in [0, 1], or null if the engine emits none."
    )
    polygon: Optional[List[List[float]]] = Field(
        None,
        description="Raw (possibly rotated) quad [[x, y], ...] in absolute pixels; null if none.",
    )


class ExtractResult(BaseModel):
    """The full /extract response. `tokens` is the reading-order token stream."""

    engine: str = Field(..., description="Engine key, e.g. 'paddleocr' | 'dots-ocr' | 'tesseract'.")
    engine_version: str = Field(..., description="Human-readable version of the underlying model/lib.")
    image: ImageSize
    tokens: List[Token] = Field(default_factory=list)
    latency_ms: float = Field(..., description="Server-side extract wall-clock, milliseconds.")


def make_token(
    text: str,
    bbox: List[float],
    width: int,
    height: int,
    confidence: Optional[float] = None,
    polygon: Optional[List[List[float]]] = None,
) -> Token:
    """Build a Token, deriving bbox_norm from the image size so no engine has to.

    Guards the width/height==0 edge (an empty/greyscale decode) by treating the
    normalizer as 1, which keeps bbox_norm finite instead of emitting inf/nan.
    """
    w = float(width) or 1.0
    h = float(height) or 1.0
    x0, y0, x1, y1 = (float(v) for v in bbox)
    # Normalize regardless of engine ordering; clamp to a sane [0, 1] so a box that
    # slightly overshoots the image edge (rounding) does not leak >1 into consumers.
    def _clamp(v: float) -> float:
        return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)

    bbox_norm = [
        _clamp(x0 / w),
        _clamp(y0 / h),
        _clamp(x1 / w),
        _clamp(y1 / h),
    ]
    return Token(
        text=text,
        bbox=[x0, y0, x1, y1],
        bbox_norm=bbox_norm,
        confidence=confidence,
        polygon=polygon,
    )


def polygon_to_bbox(polygon: List[List[float]]) -> List[float]:
    """Axis-aligned envelope [x0, y0, x1, y1] of a polygon [[x, y], ...]."""
    xs = [float(p[0]) for p in polygon]
    ys = [float(p[1]) for p in polygon]
    return [min(xs), min(ys), max(xs), max(ys)]
