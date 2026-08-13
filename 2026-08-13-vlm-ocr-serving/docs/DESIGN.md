# Design: the unified /extract contract

This project serves several OCR / document-VLM engines behind ONE HTTP contract so a
downstream verifier can treat them as interchangeable, independent evidence channels and
compare them token-for-token. This document fixes that contract, the coordinate
convention, and why the engine set looks the way it does.

## Why one contract, several engines

A document reader's confident misread is the hard failure: the value is plausible and
internally consistent, so a single reader (and a self-check by that same reader) accepts
it. The defence is a second, INDEPENDENT reading whose errors are uncorrelated with the
first — if two independent channels agree on a value AND on where it sits on the page, the
reading is far more trustworthy; if they disagree, that is precisely the signal to abstain
or escalate.

For independence to buy anything, the channels must actually be diverse. VLM-based readers
share training data and failure modes, so two VLMs tend to make the SAME mistakes
(correlated errors buy little). The engine set is therefore deliberately mixed:

| engine | kind | grounding | confidence | role |
|---|---|---|---|---|
| `paddleocr` | PP-OCR detector + recognizer (CV, CPU) | rotated quad per line | per-line score | high-recall CV channel |
| `dots-ocr` | document VLM (~3B) | layout block bbox | none | structure-aware VLM channel |
| `tesseract` | classic LSTM OCR (CV) | word box | per-word score | independent, non-VLM channel |

Tesseract earns its place not as the most accurate reader but as the one whose errors are
least correlated with the VLM, and it emits a real per-word confidence the VLM readers do
not. A consumer that wants a fourth channel adds one behind the same contract.

## The contract

`POST /extract` with an image (raw body, or multipart field `image`/`file`) returns:

```json
{
  "engine": "paddleocr",
  "engine_version": "paddleocr 2.9.1 (lang=en)",
  "image": { "width": 1000, "height": 1400 },
  "tokens": [
    {
      "text": "12.000",
      "bbox": [812.0, 640.0, 902.0, 668.0],
      "bbox_norm": [0.812, 0.457, 0.902, 0.477],
      "confidence": 0.981,
      "polygon": [[812,641],[902,640],[901,668],[813,669]]
    }
  ],
  "latency_ms": 84.2
}
```

Also served: `GET /healthz` (liveness — process up; does NOT require the model, so a slow
load never trips liveness) and `GET /readyz` (readiness — 200 only once the model is loaded,
gating the Service until the pod can actually serve).

### Coordinate convention (identical for every engine)

- `bbox` is `[x0, y0, x1, y1]` in ABSOLUTE PIXELS, origin at the TOP-LEFT, x right, y down,
  axis-aligned (`x0<=x1`, `y0<=y1`).
- `bbox_norm` is `bbox` divided by `(w, h, w, h)`, each value clamped to `[0, 1]`, so boxes
  are comparable across engines even if one internally downscaled the image.
- `polygon` (optional) is the raw, possibly-rotated quad `[[x, y], ...]` in absolute pixels;
  `bbox` is its axis-aligned envelope. Engines that only give an axis-aligned box omit it.
- `confidence` is in `[0, 1]`, or `null` when the engine emits no per-token score. Null is
  reported honestly (never a fabricated `1.0`) so a consumer can tell "the engine is sure"
  from "the engine has no opinion" — the distinction selective verification keys on.

## What the servers do NOT do: field-value localization

The contract is about GROUNDED TOKENS (text + where + how sure), not parsed fields. Mapping
"the total is 12.000" to a specific token — keyword-to-nearest-value, spatial-proximity
matching (SICM-style) — is a CLIENT concern layered on the token stream, for two reasons:

1. It keeps every engine at the same primitive, so channels stay directly comparable and a
   new engine only has to emit tokens.
2. Localization strategy is a research variable (which keyword, which proximity metric,
   which reading-order tie-break); baking one choice into the server would freeze it.

`scripts/run_smoke.py --find TEXT` is the minimal client-side locate: it reports which
engines read a given string and at what box. A verifier builds richer field binding on top
of the same `/extract` responses.

## Serving choices

- One shared FastAPI harness (`image/common/serve.py`) loads exactly one engine module per
  image (named by `ENGINE_MODULE`) and owns everything cross-cutting: request decoding to an
  RGB image, timing, filling image size + latency, and the health/readiness endpoints. Each
  engine module implements only `load()` and `extract(image) -> [Token]`.
- Model weights are baked into the image at build time (PP-OCR models, the dots.ocr ~3B
  weights, tesseract's traineddata), so a pod does NO network fetch at startup. This keeps
  serving stateless (no PVC) — a good fit for a cluster whose only StorageClass is EBS.
- Readiness is eager: `/readyz` flips true only after the model loads, so a Service that is
  Ready can serve. Liveness is on `/healthz` (process-level) so a slow model load is not
  mistaken for a hang and killed.
- Images are built in-cluster with rootless BuildKit via the shared `image-builder-lib`
  library chart (no local Docker). A single build context (`image/`) holds all three
  Dockerfiles; each build selects its `Dockerfile.<engine>` by filename and every image
  COPYs the shared `common/` harness from that one context.
