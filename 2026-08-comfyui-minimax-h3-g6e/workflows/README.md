# MiniMax-H3 workflows

The pinned official Comfy-Org templates (UI format) plus a ready-to-run **API-format** T2V
workflow that `../scripts/run_smoke.py` submits directly — no manual UI export needed for T2V.

## Files

| File | What it is |
|---|---|
| `video_minimax_h3_t2v.api.json` | **Text-to-video, API format — RUN THIS.** Submit with `run_smoke.py`. |
| `video_minimax_h3_t2v.ui.json` | Official text-to-video template (UI format, reference) |
| `video_minimax_h3_i2v.ui.json` | Official image-to-video template (UI format, reference) |
| `.workflow_templates_sha` | Exact `Comfy-Org/workflow_templates` commit the `.ui.json` files came from |

The `.ui.json` files are pinned to commit `f1604424815ffde8fed20543ac38bf245807fbca`.

## Running the T2V workflow

```bash
# ComfyUI reachable via ../scripts/port-forward.sh (http://localhost:8188)
python3 ../scripts/run_smoke.py video_minimax_h3_t2v.api.json --out ../out \
  --prompt "your scene + audio description" --prompt-node 104 --seed 77
```

Verified end to end on a single L40S (g6e.4xlarge): 20 sampling steps, ~10 min for the first
run (model load included), producing an 864x480 / ~5s H.264 clip with synchronized AAC audio.

## How the API workflow was built (and why it is NOT a UI export)

The official `.ui.json` template is **UI format** (`nodes`/`links`/`groups`) and wraps its core
nodes in a `definitions.subgraphs` **subgraph** that also pulls in two custom nodes
(`ComfyMathExpression`, `ResolutionSelector`) for resolution/duration math. ComfyUI's `/prompt`
endpoint needs **API format**: a flat `{ "<id>": { "class_type", "inputs" }, ... }` map.

Rather than depend on those custom nodes or a fragile blind conversion,
`video_minimax_h3_t2v.api.json` is a hand-built graph using **only core nodes**, with each
node's inputs verified against the live instance (`GET /object_info/<node>`) and the resolution
/ length inlined as literals (864x480, length=124 ≈ 5s on the model's 17k+5 grid). Every node
was confirmed present and every required input satisfied before the first run.

To regenerate or tweak: edit node `104` (`MiniMaxH3ImageToVideo`) `width`/`height`/`length`, or
node `9` (`BasicScheduler`) `steps`. `--prompt-node 104` targets the single prompt input; there
is no negative prompt in this graph.

### If you need I2V or R2V

There is no committed API graph for those yet. Either build one the same way (query
`/object_info` for the extra nodes and wire by hand), or let ComfyUI export it: open the
`.ui.json` in the Web UI, enable **Settings → Dev mode options**, then **Save (API Format)**.

## Node topology (T2V)

```
UNETLoader(minimax_h3_fl2va_pruned_int8_convrot.safetensors) ── model ─┬─ BasicGuider ─┐
CLIPLoader(qwen3vl_32b_...nvfp4_awq, type=minimax) ─ clip ─┐            │               │
VAELoader(minimax_h3_video_vae_fp16) ─ vae ────────────────┼─ MiniMaxH3ImageToVideo     │
                                          (prompt,w,h,len) ─┘   ├─ positive(COND) ───────┘
                                                                └─ LATENT ─┐
RandomNoise ─ KSamplerSelect ─ BasicScheduler(model) ───────────── SamplerCustomAdvanced ─ LATENT
                                                                       ├─ VAEDecode(video vae) ─ IMAGE ─┐
                                                                       └─ VAEDecodeAudio(audio vae) ─ AUDIO ─┤
                                                                              CreateVideo(fps=24) ──────────┘ ─ SaveVideo
```

The filenames match what `../charts/comfyui` fetches and where it places them, so once the
weights are on the shared volume the workflow loads them without edits.
