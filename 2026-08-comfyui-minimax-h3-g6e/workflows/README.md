# MiniMax-H3 workflows

Pinned copies of the official Comfy-Org MiniMax-H3 templates, plus notes on the one format
conversion you must do once to drive them from the CLI.

## Files

| File | What it is |
|---|---|
| `video_minimax_h3_t2v.ui.json` | Text-to-video template (**UI format**) |
| `video_minimax_h3_i2v.ui.json` | Image-to-video template (**UI format**) |
| `.workflow_templates_sha` | Exact `Comfy-Org/workflow_templates` commit these were pulled from |

Pinned to commit `f1604424815ffde8fed20543ac38bf245807fbca` for reproducibility. Re-pull with
the sha in `.workflow_templates_sha`, not `main`.

## UI format vs API format (important)

These templates are in ComfyUI **UI format** (they have `nodes` / `links` / `groups`, and the
T2V graph wraps its core nodes in a `definitions.subgraphs` **subgraph**). ComfyUI's `/prompt`
HTTP endpoint — what `../scripts/run_smoke.py` posts to — needs **API format**: a flat
`{ "<node_id>": { "class_type": ..., "inputs": {...} }, ... }` map with the subgraph expanded.

There is no reliable, offline UI→API converter (socket names and subgraph expansion depend on
the exact node versions loaded), so the honest one-time step is to let ComfyUI itself export it:

1. Port-forward ComfyUI and open the Web UI (see `../docs/GETTING_STARTED.md`).
2. Menu → **Open** the `.ui.json` template. ComfyUI resolves the subgraph against the nodes
   actually installed in the running build.
3. Enable **Settings → Enable Dev mode options**, then menu → **Save (API Format)**.
4. Save the result here as `video_minimax_h3_t2v.api.json`.

`run_smoke.py` then submits that API-format file headlessly. This is the smallest amount of
manual interaction that guarantees the node/socket names match the live instance — inventing an
API graph blind would break the moment a node input was renamed upstream.

## Core nodes (T2V)

Confirmed from the template subgraph, so you know what the models feed:

```
UNETLoader(minimax_h3_fl2va_pruned_int8_convrot.safetensors)  ─┐
CLIPLoader(qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors, minimax)│→ MiniMaxH3ImageToVideo
VAELoader(minimax_h3_video_vae_fp16.safetensors)  ──────────────┘   → SamplerCustomAdvanced
VAELoader(minimax_h3_audio_vae_fp32.safetensors)                    → VAEDecode / VAEDecodeAudio
                                                                    → CreateVideo → SaveVideo
```

The filenames match what `../charts/comfyui` fetches and where it places them, so once the
weights are on the shared volume the template loads them without edits.
