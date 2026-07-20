# Porting notes (slime -> miles)

Record of porting the parent (slime) training-inference mismatch study to
[miles](https://github.com/radixark/miles), slime's direct fork. miles diverged from slime
at fork point `fcce96ca0` (2025-10-05) and rewrote the train loop sync -> async, but the
`train.py` CLI and the mismatch-measurement flags are compatible (verified on hardware).

## Why miles

- miles targets CUDA 13.0.1 / PyTorch 2.11 / Blackwell (sm_103) as first-class. Where the
  slime image reached sm_103 via an NGC base plus hand patches, the miles image already
  applies the sm_103 Transformer Engine FA2 whitelist patch.
- miles has features slime lacks (fp8 rollout, fully-async, true-on-policy) -- out of scope
  here, but future material.

## Docker strategy C: miles official image + EFA layer

miles's dependencies (the sglang-miles fork, radixark/Megatron-LM fork, prebuilt
flash_attn/TE/apex wheels) are built for the PyTorch 2.11 stable + cu130 ABI and do not
load on an NGC (nightly ABI) base. So the image takes `radixark/miles:<dated-tag>` as the
base and adds only the AWS EFA stack (`miles.Dockerfile`):

- remove IB libverbs (let the EFA installer's libfabric win)
- gdrcopy (GPUDirect RDMA)
- EFA installer 1.48.0 (`--skip-kmod`, libfabric + aws-ofi-nccl plugin)
- NCCL/EFA runtime env (`FI_PROVIDER=efa` etc.), `GLOO_SOCKET_IFNAME=eth0`
- `PYTHONPATH=/root/miles:/root/Megatron-LM` (miles does not bake this into the image)

Pin a dated tag (`dev-202607182122`, cu13), never `:latest`, per awsome-distributed-ai
CONTRIBUTING.

## slime -> miles changes (recipe / launcher)

| Item | slime | miles |
| --- | --- | --- |
| framework install dir | `/opt/slime` | `/root/miles` (editable install) |
| Megatron | `/opt/Megatron-LM` | `/root/Megatron-LM` (radixark fork) |
| recipe runtime-env PYTHONPATH | `/opt/Megatron-LM` | `/root/Megatron-LM:/root/miles` |
| launcher `SLIME_DIR` default | `/opt/slime` | `/root/miles` (variable name kept) |
| model script | `scripts/models/qwen3-4B.sh` | same (path compatible) |

The `train.py` flags are unchanged.

## Mismatch flag compatibility (confirmed)

miles's `miles/utils/arguments.py` has every flag this study uses, with the same names and
meaning as slime:

- `--get-mismatch-metrics` (measurement-only, loss unchanged)
- `--custom-tis-function-path` (dotted or `file.py:func`;
  `examples.train_infer_mismatch_helper.mis.compute_mis_weights_with_cp`)
- `--custom-config-path` (TIS/RS parameter YAML)
- `--use-tis` / `--use-rollout-logprobs` (mutually exclusive; same assert on miles)
- the `--get-mismatch-metrics` requires `--custom-tis-function-path` assert is identical

miles ships `examples/train_infer_mismatch_helper/{mis.py,mis.yaml}` identical to slime, so
the `configs/*.yaml` are reused as-is. SGLang passthrough (`--sglang-kv-cache-dtype
fp8_e5m2` etc.) works the same way (ServerArgs auto-expose).

### miles-native TIS path (difference, for reference)

Besides the slime-compatible path above, miles has a first-class TIS implementation in
`loss_hub/corrections.py` (`vanilla_tis_function`, `icepop_function`) controlled by
`--tis-clip` / `--tis-clip-low`. This study uses the slime-compatible path
(`--use-tis` + `--custom-config-path`) to keep the comparison exact.

## Pitfalls found on real hardware (2026-07-19)

All three occur on the miles base (nvidia/cuda) and NOT on slime's NGC base, and are fixed
in `miles.Dockerfile` / the manifests.

### 1. CUDA compat shadowing -> torch.cuda dies (Error 803)

Carrying slime.Dockerfile's EFA layer verbatim also carries
`ENV LD_LIBRARY_PATH=...:/usr/local/cuda/compat:...`, which is fatal on the miles base:

- The miles base bundles a CUDA forward-compat libcuda `580.82.07`.
- The validation node's host driver is `580.159.03` (nvidia-smi shows "CUDA Version: 13.0").
- CUDA forward-compat requires compat >= host driver. When the older compat (580.82.07) is
  preferred via LD_LIBRARY_PATH, torch.cuda dies with `RuntimeError: ... Error 803: system
  has unsupported display driver / cuda driver combination`, and the SGLang engine fails at
  `get_device()` ("No accelerator available").
- Verified: dropping compat from LD_LIBRARY_PATH restores `torch.cuda.is_available() == True`.
- Fix: `miles.Dockerfile` deletes `/usr/local/cuda*/compat` outright and uses the host
  driver (`/usr/lib64/libcuda.so`), which already supports the image's CUDA 13.0 toolkit.
  slime (NGC) could use compat because NGC's entrypoint enables it only when compat >= host.

### 2. libcuda.so.1 not found in the SGLang subprocess

With compat gone, torch still works (ld.so.cache resolves libcuda), but the SGLang server
subprocess (and Triton / cuda-python loaders, which scan LD_LIBRARY_PATH directly rather
than the cache) fail with `ImportError: libcuda.so.1: cannot open shared object file`. Fix:
append the driver-injection dirs (`/usr/lib64`, `/usr/lib/x86_64-linux-gnu`) to
LD_LIBRARY_PATH and register them with `ldconfig`. Appending (not prepending) means they
are consulted only for libraries nothing else resolves.

### 3. Ray job driver dies on the head (no libcuda)

miles's `MegatronTrainRayActor` imports `mooncake` (P2P weight transfer, libcuda-dependent)
at module load. The Ray job driver runs on the head, which is a non-GPU pod with no libcuda
injected, so the driver dies with the same `ImportError: libcuda.so.1`. Fix: declare a
`gpu_node` custom resource on the worker (`rayStartParams.resources: '{"gpu_node": 1}'`)
and submit with `ray job submit --entrypoint-resources '{"gpu_node": 0.001}'`, which places
the driver on a GPU worker without consuming a GPU logical count (so it does not conflict
with the colocated 8-GPU placement group). Note: `begin_weight_update` / `pull_weights` are
Ray actor methods on miles's rollout engine (`sglang_engine.py`), not HTTP endpoints on an
SGLang fork.

## Known Issue

- `save_model()` fails with `_pickle.UnpicklingError: pickle data was truncated` in
  Megatron's distributed checkpoint save (`gather_object`), independent of the GRPO loop.
  Blocks the HF<->Megatron round-trip and long checkpointing runs. File upstream on miles.

## Residual patches (of slime's 7, what remains on miles)

- `--sglang-log-level warning` (lowercase; avoids the uvicorn KeyError; recipe-only).
- GPU-less Ray driver Megatron `validate_args` CUDA probe (may surface for 30B MoE; may
  already be fixed in the radixark fork -- UNVERIFIED).

The numpy<2 pin, torch_memory_saver preload `.so` selection, and manual mbridge pin are all
resolved by the miles official image.
