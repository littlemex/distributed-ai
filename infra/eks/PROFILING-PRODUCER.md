# Profiling a workload

Put `kubectl-accelprof` on your PATH — it is a single self-contained file, so copying it is enough —
and run your own command under a profiler:

```bash
kubectl accelprof run --alias team1-lora-sweep --image "$MY_IMAGE" -- python train.py --lr 3e-4
```

It returns as soon as the run is submitted. The recording happens in the cluster, so nothing on your
machine has to stay alive. When it finishes, ask for the run:

```bash
kubectl accelprof get "$WORKLOAD_ID"
kubectl accelprof runs --alias team1-lora-sweep
```

You need nothing but `kubectl`: no repository checkout, no Helm, no Python. Everything about the
platform — the region, the trace bucket, the MLflow tracking server, the image that carries the
profiler — is read from the `accelprof-config` ConfigMap that the platform publishes into your
namespace. If that ConfigMap is missing, the namespace has not been wired for profiling yet; ask the
platform owner to add it to `PRODUCER_NAMESPACES` and re-run `infra/scripts/install-profiling.sh`.

## Your image needs nothing

The profiler is copied out of the platform image into a shared volume before your container starts,
and the recording is done by a second container running the platform image. Your training image
carries no profiler, no `accelprof` package and no particular Python version. If your image already
ships `nsys`, pass `--no-inject-nsys` and the copy is skipped.

## Leaving metrics behind

To attach numbers to the run, write a file. No import, no library, and nothing that breaks when the
same script runs outside the cluster:

```python
import json
json.dump({"tokens_per_sec": tps, "loss": loss}, open("/accelprof/out/metrics.json", "w"))
```

The whole contract is one directory, `/accelprof/out`, and every part of it is optional:

| Path | Meaning |
| --- | --- |
| `metrics.json` | flat JSON object of numbers, recorded as metrics |
| `params.json` | flat JSON object, recorded as params |
| `tags.json` | flat JSON object of strings, recorded as tags |
| `artifacts/` | any files to keep with the run |
| `traces/` | written for you by the profiler |

A malformed file is reported and skipped rather than failing the run: losing a finished experiment to
a typo in a throwaway script is worse than a run with no metrics.

## Naming: one alias per campaign

An alias is simultaneously the MLflow experiment name and the top-level prefix of the trace bucket,
which makes it the unit of deletion, of retention, of what the analysis server can see, and of
cleanup. Use one alias per experiment campaign, named `tenant-series`, and vary the run's variants
inside it:

```bash
kubectl accelprof run --alias team1-attn-sweep --image "$MY_IMAGE" \
  --param seq_len=4096 --tag variant=flash -- python train.py --seq-len 4096
```

Minting an alias per run multiplies the deletion and retention units instead, and a campaign then
cannot be cleaned up in one step. `workload_id` identifies the individual run and is generated for
you.

An alias is a shelf, not a boundary: everyone with access to the platform can read everyone's runs
and profiles. The platform is built for a single trust domain.

## Things you will want

| Need | How |
| --- | --- |
| GPUs | `--gpu 4` requests them and tolerates the GPU pool |
| Neuron devices | `--neuron 1` |
| A run with no profile, as a baseline | `--profile none`. It is still recorded, so it sits beside its profiled siblings |
| Different profiler options | `--nsys-args "-t cuda,nvtx,cudnn --capture-range=cudaProfilerApi"` |
| Environment variables | `--env NCCL_DEBUG=INFO` (repeatable) |
| Volumes, affinity, pull secrets, sidecars | `--patch overlay.yaml`, a strategic-merge patch against the Job |
| To watch one short run | `--wait` |
| The manifest, for GitOps | `--dry-run` |

Anything the flags do not cover is reachable through `--patch`, and the flags never re-model what
Kubernetes already expresses: resources, tolerations and volumes are passed through as written.

## Which ranks get profiled

By default only rank 0 is, because capturing every rank of a large job multiplies the cost. That is a
sampling choice and not a representative measurement: a straggler, a skewed data shard or uneven
expert routing all hide from rank 0. Use `--profile-ranks 0,3,7` or `--profile-ranks all` when the
question is about the difference between ranks.

One launch is one run, whatever the rank count. Ranks appear as separate files in the run's artifacts
rather than as separate runs, so a campaign's runs stay comparable.

## Failed runs are kept

A workload that exits non-zero is still recorded, tagged `status=failed`, with its profile attached.
The main reason to profile something is that it is slow or crashing, so those are the runs worth
keeping. Pass `--discard-on-fail` if you disagree for a particular run.

A workload killed without warning — an out-of-memory kill, for instance — cannot write its own
status, so the recorder reads the container's state from the API and records the reason it finds. If
the whole Pod disappears (an eviction, a drained node), nothing in the Pod can record anything; an
hourly check in your namespace reports finished Jobs that have no run, so the gap is visible rather
than silent.

## Where things live

The Job is kept for two days after it finishes and then removed by Kubernetes; the recording is
permanent. `kubectl accelprof get` reads the run id from the Job while it exists, and points at MLflow
afterwards, which is the durable way to find a run by alias and workload id.
