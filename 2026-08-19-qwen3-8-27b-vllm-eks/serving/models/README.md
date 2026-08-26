# One directory per model

`scripts/deploy.sh --model <name>` reads `serving/models/<name>/` and nothing else. Everything that
differs between models lives here, so bringing a different one up is a flag rather than an edit in
four places.

| File | What it holds |
| --- | --- |
| `model.env` | The facts both engines need: repo id, served name, native window, YaRN factor |
| `profiles.env` | The window/concurrency table (`--context`) and the tuning knobs (`--tune`) |
| `values.yaml` | The vLLM overlay: image, TP, quantisation, prefix caching, tool parser |
| `FACTS.md` | Facts from the checkpoint's config, and numbers measured on this deployment |
| `sglang.yaml` | Optional. The SGLang manifest, if that engine is used for this model |

The Deployment's name is derived from the repo id by the same normalisation the chart applies, so
`--model` is a true swap: deploy.sh removes any vLLM Deployment for a different model before waiting
on the new one, because four L40S hold one engine and the old one would keep the GPUs.

```bash
ls serving/models                                   # what is available
./scripts/deploy.sh --model qwen3.6-35b-a3b --only serving --skip-pool
./scripts/deploy.sh --model qwen3.8-27b --context 131k --tune throughput --only serving --skip-pool
```

Adding a model is: copy the closest directory, put the repo id in `model.env`, work the KV geometry
out of the checkpoint's `config.json` into `profiles.env`, and leave `FACTS.md` honest about which
numbers are measured and which are still guesses.
