"""Shared FastAPI harness for every OCR/doc-VLM serving image.

One harness, three images: each image bakes in ONE engine module (paddleocr, dots-ocr,
or tesseract) plus this file, and runs `uvicorn common.serve:app`. The engine to load is
named by the ENGINE_MODULE env var (default "engine", the per-image module the Dockerfile
copies to /app/engine.py), so the harness itself is engine-agnostic.

An engine module must expose:
    ENGINE_KEY: str                       # e.g. "paddleocr"
    def version() -> str                  # human-readable model/lib version
    def load() -> None                    # load models once; called at startup
    def extract(image: PIL.Image.Image) -> list[Token]   # the actual work

The harness owns everything cross-cutting: decoding the request into an RGB image,
timing the extract, filling image size + latency, and the health/readiness endpoints.
Model loading is EAGER at startup (not lazy on first request) so readiness only flips
true once the engine can actually serve -- a Service that is Ready must be able to work.
"""

from __future__ import annotations

import importlib
import io
import os
import time

from fastapi import FastAPI, HTTPException, Request
from PIL import Image
# request.form() yields starlette's UploadFile; fastapi.UploadFile is a SUBCLASS of it, so an
# isinstance check must use the base class or it rejects every real multipart upload.
from starlette.datastructures import UploadFile

from common.extract_contract import ExtractResult, ImageSize

ENGINE_MODULE = os.environ.get("ENGINE_MODULE", "engine")

app = FastAPI(title="ocr-serving", version="0.1.0")

# Filled by _startup(); until then /readyz reports not-ready.
_engine = None
_ready = False
_load_error: str | None = None


@app.on_event("startup")
def _startup() -> None:
    global _engine, _ready, _load_error
    try:
        _engine = importlib.import_module(ENGINE_MODULE)
        _engine.load()
        _ready = True
    except Exception as exc:  # surface load failure via /readyz, do not crash-loop silently
        _load_error = f"{type(exc).__name__}: {exc}"
        _ready = False


@app.get("/healthz")
def healthz() -> dict:
    """Liveness: the process is up and serving HTTP. Does NOT require the model loaded,
    so a slow model load never trips liveness and gets the pod killed mid-load."""
    return {"status": "ok", "engine_module": ENGINE_MODULE}


@app.get("/readyz")
def readyz() -> dict:
    """Readiness: the engine loaded and can serve. Gates the Service until the model is in."""
    if not _ready:
        raise HTTPException(status_code=503, detail={"ready": False, "error": _load_error})
    return {"ready": True, "engine": getattr(_engine, "ENGINE_KEY", ENGINE_MODULE)}


async def _read_image(request: Request) -> Image.Image:
    """Accept either multipart form-data (field 'image' or 'file') or a raw image body,
    so both `curl -F image=@x.png` and `curl --data-binary @x.png` work."""
    ctype = request.headers.get("content-type", "")
    data: bytes
    if ctype.startswith("multipart/form-data"):
        form = await request.form()
        up = form.get("image") or form.get("file")
        if not isinstance(up, UploadFile):
            raise HTTPException(status_code=422, detail="multipart body needs an 'image' (or 'file') part")
        data = await up.read()
    else:
        data = await request.body()
    if not data:
        raise HTTPException(status_code=422, detail="empty request body")
    try:
        # convert("RGB") normalizes palette/CMYK/greyscale so every engine sees 3 channels.
        return Image.open(io.BytesIO(data)).convert("RGB")
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"could not decode image: {exc}")


@app.post("/extract", response_model=ExtractResult)
async def extract(request: Request) -> ExtractResult:
    if not _ready:
        raise HTTPException(status_code=503, detail={"ready": False, "error": _load_error})
    image = await _read_image(request)
    w, h = image.size
    t0 = time.perf_counter()
    tokens = _engine.extract(image)
    latency_ms = (time.perf_counter() - t0) * 1000.0
    return ExtractResult(
        engine=getattr(_engine, "ENGINE_KEY", ENGINE_MODULE),
        engine_version=_engine.version(),
        image=ImageSize(width=w, height=h),
        tokens=tokens,
        latency_ms=round(latency_ms, 2),
    )
