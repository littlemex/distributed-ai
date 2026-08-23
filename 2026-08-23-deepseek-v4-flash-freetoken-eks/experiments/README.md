# Measurements

All numbers below were measured on a live EKS cluster in `us-east-2`, not estimated. The benchmark
client runs as an in-cluster Job (`experiments/bench/run_bench.sh`) so the figures describe the
engine rather than a port-forward tunnel.

Definitions, because a single "tokens/sec" would hide the mechanism:

- **output tok/s** — aggregate output tokens across all concurrent streams / wall clock. Includes
  prefill in the wall clock, so it is lower than the decode rate.
- **decode tok/s/stream** — `1 / TPOT`, the steady-state generation rate a single user sees.
- **TPOT** — mean inter-token gap after the first token. Excludes prefill.
- **TTFT** — time to first token.

## The result

`deepseek-ai/DeepSeek-V4-Flash-0731` — 284B total / 13B active — serves from **one 45 GiB L40S**,
with its expert set page-locked in host RAM on a `g6e.8xlarge` (256 GiB).

Every configuration was sampled at least three times, because the first pass showed that a single
sample cannot separate a 10% effect from run-to-run noise. Ranges below are min-max across samples.

| Backend | conc | output tok/s | decode tok/s/stream | TPOT ms | TTFT p50 ms |
|---|---|---|---|---|---|
| offload | 1 | 7.51 – 7.52 | 11.05 – 11.06 | 90.48 – 90.50 | ~10 950 |
| offload | 2 | 10.54 – 10.87 | 9.55 – 10.11 | 98.94 – 104.75 | ~21 642 |
| offload | 4 | 16.58 – 17.73 | 7.12 | 140.46 – 140.48 | 21 896 – 25 912 |
| **hybrid** | 1 | **9.03 – 10.07** | **14.69 – 17.68** | **56.57 – 68.06** | ~10 951 |
| **hybrid** | 2 | **10.75 – 12.00** | 9.91 – 12.26 | 81.55 – 100.91 | ~21 641 |
| **hybrid** | 4 | **19.20 – 20.87** | 9.27 – 10.80 | 92.55 – 107.93 | 21 900 – 25 849 |

**`--moe-backend hybrid` is a real win, and the sample ranges do not overlap** at concurrency 1 or
4: +20% to +34% aggregate throughput at c=1, +8% to +26% at c=4. The cleanest signal is TPOT at
c=1, where offload is extraordinarily tight (90.48 / 90.50 / 90.5 ms) and hybrid never comes near
it (56.6 – 68.1 ms), a 25-37% reduction. At concurrency 2 the ranges do overlap, so the effect
there is not established.

TTFT is unchanged by the backend, which is the expected signature: hybrid only changes how a
*decode-time* expert miss is serviced, and TTFT is prefill-dominated.

That difference in reproducibility is itself informative. Offload is bandwidth-bound on a fixed
PCIe path and repeats to within 0.1% at c=1; hybrid distributes work across 24 CPU threads and
spreads over roughly ±10%. Any future comparison of hybrid variants needs repeats.

### `ft bench bw`: why hybrid wins, and what tuning the split did not buy

The bench runs as an initContainer on the node the pod actually landed on (`benchBw.enabled`),
because FreeToken discards a profile whose recorded GPU name does not match the running GPU. It
builds synthetic banks capped at 2 GiB, so it never reads the checkpoint. On this hardware:

```
gpu cuda:0 (NVIDIA L40S)   cpu 16c/16t
ceilings: CPU STREAM read 77.7  |  PCIe linear H2D 13.5  D2H 13.2  GB/s   (threshold 2.0x)

format      expert       CPU-MoE   PCIe-gather  CPU/PCIe  backend
ds_fp4    12.75 MB     61.9 GB/s     13.5 GB/s     4.59x  hybrid
   overlapped: CPU-MoE 59.3 + PCIe 13.4 GB/s -> hybrid fetches 18.5% of misses
```

This is the mechanism behind the table: **the CPU retires an expert 4.59x faster than PCIe can
deliver one**, and overlapping the two paths offers 72.7 GB/s against PCIe's 13.5 GB/s alone. That
is why moving miss handling onto the CPU pays at all.

With the profile in place the engine switched from its fallback to the measured split:

```
--moe-hybrid-max-fetch auto: fetching 18.5% of each decode step's expert misses over PCIe
(benched PCIe/CPU bandwidth ratio), the rest on the CPU
```

**But the measured split did not beat the fallback.** Without a profile FreeToken warns and caps
fetches at one per layer per step; that fallback produced 9.04 / 12.00 / 20.70 tok/s, and the
benched 18.5% produced 9.03 – 10.07 / 10.75 – 11.94 / 19.20 – 20.87 — indistinguishable given
hybrid's own ±10% spread. An initial single-sample read suggested the profile was 7-10% *worse*;
repeating it showed that was noise.

So the useful conclusion is narrower than "run the bench and go faster": the win comes from
**using the CPU at all**, not from tuning how much of each step crosses PCIe. The bench is still
worth running for what it explains (the 4.59x ratio, and hence why hybrid rather than offload) and
because `--moe-backend auto` consults the same profile to make that choice for you. It is not,
on this hardware and at this concurrency, a throughput knob.

## Quantization: FP4 experts, FP8 dense

Worth stating precisely, because "is it FP8?" has two different answers in the same checkpoint:

| Part | Format | Where |
|---|---|---|
| routed experts (the 143 GiB) | **DS-FP4** — packed e2m1 codes + e8m0 per-32 block scales | `offload_cache._BANK_SCHEMAS["ds_fp4"]`, four banks |
| attention / dense | **FP8 e4m3, 128x128 block scales, kept AS FP8** | `deepseek_v4/weight.py` ("dtype (fp8 + e8m0 preserved)") |
| `wo_a` projection | dequantized to **bf16** | to match the reference bf16 einsum |

So the mass of the model is FP4, not FP8, and that is the only reason 284B parameters occupy 143 GiB
of banks at all. The bench confirms the runtime path: `fmt=ds_fp4`, 12.75 MB per expert.

There is no lower-precision knob to reach for here: the checkpoint ships pre-quantized in these
formats and FreeToken reads them natively rather than re-quantizing.

## Speculative decoding and MTP: not available

DeepSeek-V4-Flash ships an MTP (multi-token prediction) head — `deepseek_v4/args.py` carries
`n_mtp_layers: int = 1` — and FreeToken **deliberately discards it**:

```python
if int(m.group("layer")) >= L:  # skip the MTP layer (index L)
```

`deepseek_v4/weight.py` does this in both its expert and dense loaders, and the GLM and Qwen3.5
loaders do the same. `ft serve` exposes **no** speculative flags of any kind: grepping
`server/args.py` for `speculative|draft|mtp|eagle` returns nothing. The EAGLE tree-mask constants in
`kernel/fla/` are inherited from upstream flash-linear-attention and are not reachable from the
server.

This produces an awkward but important situation:

| Engine | Runs DSV4 on one 45 GiB L40S | MTP / speculative decoding |
|---|---|---|
| FreeToken | **yes** (experts in host RAM) | no |
| vLLM / SGLang | no (needs the weights in VRAM) | yes |

The engine that can run this model on this GPU is the one without MTP, and the engines with MTP
cannot fit the model. So MTP is not a tuning option today — it is an upstream feature request.

It is also not obviously a large win here even if implemented. Decode is expert-bandwidth-bound:
with `top_k=6` over 43 MoE layers, a token touches ~258 expert activations, of which ~80% miss at
19.9% residency, and each expert is 12.75 MB. Verifying k draft tokens in one step touches the
UNION of their routed experts, so speculation buys fewer steps but not proportionally fewer expert
bytes. The measured concurrency scaling (7.5 -> 16.6 tok/s from c=1 to c=4 on offload) is the same
amortization effect and is available today by raising `maxRunningRequests`.

## Context: YaRN reaches 1M in principle, the KV pool does not

YaRN is not something to enable — it is already in the checkpoint and implemented in FreeToken's
DSV4 args: `original_seq_len 65536` x `rope_factor 16` = **1 048 576**.

Setting `maxSeqLenOverride: 1048576` starts cleanly and `/v1/models` duly reports
`ctx: 1048576`. **The allocation does not change at all**, because the KV pool is sized by dividing
the VRAM budget, not by the declared ceiling — it stayed at exactly the 32 768-cap numbers
(501 pages / 64 128 tokens / 2.09 GiB). A long prompt is then refused by the engine itself:

```
prompt is too long: 152010 tokens > 64128 maximum (prompt + generation);
shorten the prompt or increase the KV cache budget
```

So the advertised context is a ceiling, and the real one is the KV pool. `--kv-reserve-tokens` is
the budget knob, and it converts expert cache into context one for one:

| `kvReserveTokens` | usable context | KV VRAM | `moe_cache_size` | residency | c=1 tok/s | c=4 tok/s | c=4 TPOT ms |
|---|---|---|---|---|---|---|---|
| 8 192 (baseline) | 64 128 | 2.09 GiB | 2 193 | **19.9%** | 9.03 – 10.07 | 19.20 – 20.87 | 92.55 – 107.93 |
| 262 144 | **262 272** | 8.50 GiB | 1 662 | **15.1%** | 8.85 | 17.62 | 125.94 |

**4.1x the context costs about 8-16% aggregate throughput at concurrency 4** (and a clearly worse
TPOT: 126 ms against 93-108 ms). At c=1 the difference is inside the ±10% noise.

That trade is cheaper than the 24% cut in expert slots suggests, and the reason is instructive: at
19.9% residency the miss rate is already 80.1%, so dropping to 15.1% only raises it to 84.9% — a 6%
increase in expert traffic. **Deep in the miss-dominated regime, marginal residency is nearly
free.** The corollary is the unwelcome one: buying speed by raising residency is correspondingly
expensive, and 100% residency would need 11 008 x 12.75 MB = 140 GiB of VRAM.

The two measured points also fix the total budget at ~29.3 GiB for KV plus expert cache
(2.09 + 27.3 and 8.50 + 20.8). A 1M-token pool needs 8 192 pages at ~4.25 MiB/page = **~34.8 GiB**,
which exceeds that budget *even with the expert cache set to zero*. The hard ceiling on one 45 GiB
L40S is therefore roughly **880k tokens with no expert cache at all** — i.e. 1M is not reachable
here at any speed, and the practical ceiling is well below it.

## Concurrency is the largest lever found

`maxRunningRequests` was 4 in both profiles because that is FreeToken's default. Raising it to 16
(hybrid, otherwise identical) is the biggest single improvement measured anywhere in this work:

| conc | output tok/s | decode tok/s/stream | TPOT ms | TTFT p50 ms |
|---|---|---|---|---|
| 1 | 8.85 | 14.23 | 70.27 | 10 951 |
| 4 | 17.94 | 8.17 | 122.42 | 25 833 |
| 8 | **30.96** | 5.79 | 172.76 | 22 060 |
| 16 | **41.83** | 3.37 | 296.69 | 22 203 |

**41.83 tok/s against the original offload/c=4 baseline of 16.59 — 2.5x** — and 2.1x against the
hybrid/c=4 figure it should be compared to. Scaling is still positive at 16 but clearly saturating:
2.03x from c=1 to 4, then 1.73x to 8, then 1.35x to 16.

The mechanism is expert-fetch amortization. A token implies touching on the order of 2.6 GB of
expert weights (`top_k=6` x 43 layers x 12.75 MB x ~80% miss), and concurrent requests in the same
decode step share whatever that step pulls. Since the bottleneck is expert bandwidth rather than
compute, adding requests costs almost nothing in extra bytes until their routed-expert sets stop
overlapping.

Raising the cap slightly reduced residency, as expected — a larger working set reserves more KV:

| | KV tokens | KV VRAM | `moe_cache_size` | residency | CUDA graphs |
|---|---|---|---|---|---|
| maxRunningRequests 4 | 64 128 | 2.09 GiB | 2 193 | 19.9% | [1, 2, 4] |
| maxRunningRequests 16 | 71 808 | 2.34 GiB | 2 109 | 19.2% | [1, 2, 4, 8, 16] |

Graph coverage extended to the new batch sizes, so the c=8 and c=16 points are not measuring an
eager-execution fallback.

**This is a throughput setting, not a latency one.** Per-stream decode falls 14.23 -> 3.37 tok/s and
TPOT rises 70 -> 297 ms across the sweep. At 16 concurrent requests a single user sees roughly 3.4
tokens per second, which serves a batch workload well and an interactive one poorly. Choose the cap
from the workload, not from the aggregate number.

The KV pool is also a real ceiling here: 71 808 tokens shared across 16 running requests is ~4 500
tokens each. Long-context and high-concurrency compete for the same budget, on top of both
competing with the expert cache.

## What would actually make decode faster

Ordered by what the measurements support:

1. **Raise `maxRunningRequests`** — MEASURED, and the largest win available: 4 -> 16 gives
   41.83 tok/s aggregate, 2.5x the original baseline. Costs per-stream latency (TPOT 122 -> 297 ms),
   so it is a batch lever. Still scaling at 16, though saturating.
2. **`--moe-backend hybrid`** — measured, +20-34% at c=1, and already applied.
3. **A CPU with AVX-512, and more VRAM** — attempted on `g7e.8xlarge` (Intel + 96 GiB VRAM) and
   **blocked by EC2 capacity in every AZ that offers it**, not by configuration. FreeToken does ship
   `dot_dsfp4_avx512`, and g6e's AMD Milan is why the bench reports `isa=avx2`. See
   [`hardware/README.md`](hardware/README.md) for the rationale, the exact capacity errors, and how
   to retry.
4. **More VRAM per GPU**, to raise residency. This is the only first-order fix for the 80% miss
   rate, and it is a hardware decision rather than a tuning one.
5. **Not** the `ft bench bw` fetch split, which was measured and did not help (above).

## Why the numbers are what they are

The single measurement that explains everything else, from `/v1/cache/status`:

| | DeepSeek-V4-Flash | gpt-oss-20b |
|---|---|---|
| experts per layer x layers | 256 x 43 = **11 008** | 32 x 24 = **768** |
| `moe_cache_size` (VRAM slots) | **2 193** | **768** |
| resident share | **19.9%** | **100%** |
| bytes per expert | 12.8 MiB | 12.6 MiB |
| expert cache VRAM | 27.3 GiB | 9.7 GiB |
| KV allocated | 2.09 GiB (64 128 tok) | 26.55 GiB (965 172 tok) |

For DSV4 only one expert in five is resident, so roughly four of five expert accesses miss and must
be serviced over PCIe or on the CPU. That is the entire gap between 11 tok/s and gpt-oss-20b's 147
tok/s decode — not model size as such, but *residency*.

The contrast is worth stating plainly because it changes what the smoke profile proves:

| | gpt-oss-20b (g6e.xlarge) | DeepSeek-V4-Flash (g6e.8xlarge) |
|---|---|---|
| conc 1 output tok/s | 96.86 | 7.52 (offload) / 9.04 (hybrid) |
| conc 4 output tok/s | 236.45 | 16.59 (offload) / 20.70 (hybrid) |
| conc 1 decode tok/s | 147.06 | 11.06 / 14.73 |
| conc 1 TTFT | 894 ms | 10 951 ms |

gpt-oss-20b's entire expert set fits in VRAM (768 of 768 slots), so its "offload" run streams
**nothing** over PCIe. It validates the image, chart, pool, and S3 Files mount, and it is a useful
upper bound, but it does not exercise the offload mechanism at all. Only the DSV4 numbers describe
what offloading costs.

`gpt-oss-20b` also spends its output on the reasoning channel: it streams `reasoning_content`
deltas and emits `content` only at the end, so a benchmark that counts only `content` reports zero
throughput on a fully busy GPU. `bench.py` counts both.

## Checkpoint load over S3 Files

The expert banks are read from the shared S3 Files (NFS) mount and page-locked. Measured on the
`g6e.8xlarge`:

| | value |
|---|---|
| expert bank bytes | 153 904 798 576 (**143.3 GiB**) |
| sustained read | **~546 MB/s** |
| bank load wall clock | **4 min 38 s** |
| process start to `status: ok` | **~6 min** (banks + warmup + CUDA graph capture) |

For comparison, the same mount read from an `m5a.xlarge` CPU node measured **232.8 MB/s** — the
mount is not the ceiling, the instance's network is. This settles the open question both reviews
raised: reading 160 GB in place over NFS costs about five minutes, not tens of minutes, so local
NVMe staging is not required to make the load tolerable.

The checkpoint transfer into the bucket (73 objects, 166.9 GB, streamed file-by-file by an
in-cluster Job) took **16 min** at roughly 172 MB/s.

`/health` is a progress endpoint during load, which is what made the above measurable:

```json
{"status":"loading","phase":"expert_banks",
 "progress":{"done_bytes":103000000000,"total_bytes":153904798576}}
```

It returns HTTP 200 throughout, so an `httpGet` probe on `/health` reports Ready while the model is
still loading — see the note in `serving/charts/freetoken-serving/values.yaml`.

## Reproducing

```bash
./experiments/bench/run_bench.sh --concurrency 1,2,4 --max-tokens 256 --follow
```

hybrid is now the SHIPPED DEFAULT of `serving/values/deepseek-v4-flash.values.yaml`, so
`./scripts/deploy.sh --profile dsv4` reproduces the hybrid rows directly. To reproduce the offload
baseline rows instead, layer the control overlay:

```bash
helm template x serving/charts/freetoken-serving \
  -f serving/values/deepseek-v4-flash.values.yaml \
  -f experiments/moe-backend/dsv4-offload-baseline.values.yaml \
  --set image=<ecr-image> -n freetoken | kubectl -n freetoken apply -f -
```

## Not measured

Stated so the table above is not read as more than it is:

- Output **quality**. Throughput only; no eval was run, and `hybrid` computing part of each layer on
  CPU is a numerics change that this benchmark cannot detect.
- Concurrency beyond 4. `maxRunningRequests` is 4 in both profiles.
- Context beyond the capped window (8 192 smoke / 32 768 DSV4) against a 1M-token native context.
- Whether the fetch/compute split matters at higher concurrency, longer prompts, or on a GPU with a
  different PCIe-to-CPU ratio. It did not matter here; that is not the same as never mattering.
- Prompt-length sensitivity. One fixed ~60-token prompt throughout, so TTFT here is close to a
  floor rather than a curve.
