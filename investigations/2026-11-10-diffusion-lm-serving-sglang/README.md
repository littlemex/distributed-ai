# Serving a diffusion LM with SGLang next to its autoregressive sibling

A diffusion language model drafts a block of tokens at once and refines it over several denoising steps, instead of producing one token per forward pass. SGLang 0.5.23 serves LLaDA 2.x models this way (`--dllm-algorithm JointThreshold`, [cookbook](https://github.com/sgl-project/sglang/blob/v0.5.23/docs/cookbook/autoregressive/InclusionAI/LLaDA-2.1.mdx)); vLLM has no diffusion text model support. This investigation puts LLaDA2.1-mini next to Ling-mini-2.0, an autoregressive model from the same group with the same 16B mixture-of-experts shape, on one H200 each, and measures latency, throughput and GSM8K accuracy.

| Run label | Model | Scheduling |
|---|---|---|
| `llada2.1-mini-mrr1` | `inclusionAI/LLaDA2.1-mini` @ `20e64e2` | the cookbook's settings: one running request |
| `llada2.1-mini-mrr8` | same | eight running requests |
| `ling-mini-2.0-ar` | `inclusionAI/Ling-mini-2.0` @ `a810f64` | default continuous batching |

Both models are Apache-2.0 and ungated.

## What is measured

| Measurement | Tool | Settings |
|---|---|---|
| Output tokens per second, time to first token, inter-token latency, end-to-end latency | `sglang.bench_serving` | random prompts, 256 input and 512 output tokens, concurrency 1 and 8 |
| Accuracy | `sglang.test.few_shot_gsm8k` | 200 questions, 5-shot, greedy |

The cookbook sets `--max-running-requests 1` for best quality. The batched run checks what a diffusion model gives up in accuracy, and gains in throughput, when it is scheduled like an autoregressive one.

## Files

```
scripts/serve_and_bench.sh   start one server on one GPU, measure, stop
scripts/summarize.py         one table across runs
tasks/10-sglang-env.json     sglang[all]==0.5.23 venv, both models at pinned revisions
tasks/20-bench.json          the three runs and the summary
```

## Run

```bash
cd ../2026-11-10-p5e-single-node-campaign
./3.run.sh 2026-11-10-diffusion-lm-serving-sglang/tasks/10-sglang-env.json
./3.run.sh 2026-11-10-diffusion-lm-serving-sglang/tasks/20-bench.json
```

## Results

Pending: the Capacity Block runs 2026-11-10 20:30 to 2026-11-11 20:30 JST.

## Contributing upstream

Serving examples in awsome-distributed-ai live at `examples/inference/<engine>/<name>/`, named model-GPU-topology, with a row in `examples/inference/README.md`. This would be `examples/inference/sglang/llada2.1-mini-h200-single-node/`, following the EC2-and-Docker shape of `examples/inference/sglang/dsr1-deepep-efa/` (`recipe/serve.sh`, `recipe/benchmark.sh`, `setup/env_vars.example`, known limitations), with the image built from the engine directory's shared Dockerfile.
