# UCCL-EP on EFA — build & run gotchas

Chronological account of what broke and how it was fixed, so this is reproducible.

## 1. The PyPI wheel does not work on a peermem-less EFA node

`pip install uccl` (wheel `uccl==0.1.1`, cp312-abi3) imports fine and `uccl.ep`
loads, but the 2-node bench crashes during CPU-proxy init:

```
RDMA buffer MR registration failed: Operation not supported
[RDMA] main RDMA buffer probe failed on NIC rdmap135s0 (bytes=67108864, errno=95: Operation not supported)
```

`errno=95 = EOPNOTSUPP`: the GPU buffer cannot be registered as an RDMA MR.

- The node runs NVIDIA Open Kernel Module 580 + EFA 3.1, and **`nvidia_peermem`
  is not loaded**.
- NCCL still gets GPUDirect over EFA because aws-ofi-nccl/libfabric uses the
  **dma-buf** path (`ibv_reg_dmabuf_mr`).
- The **prebuilt wheel uses the legacy `ibv_reg_mr` path** (needs peermem). The
  DMA-BUF path in `ep/src/rdma.cpp` (`reg_mr_gpu_dmabuf`, "avoids nvidia_peermem
  dependency") is guarded by `#ifdef USE_DMABUF`, and the wheel is built WITHOUT
  it. Confirm the failure crisply:

```python
from uccl import ep
ep.can_register_rdma_gpu_buffer(0, 64 << 20)   # => False on this node
```

Note: UCCL `v0.1.1` (the wheel's tag) has no `USE_DMABUF` plumbing in
`ep/setup.py` / `ep/Makefile` at all; it was added on `main`. So you must build
from `main`.

## 2. Build from source with USE_DMABUF=1

Done inside the NGC image on a p5en pod (`manifests/01-build-probe.yaml`). NGC
25.01 already ships rdma-core dev headers and the `/opt/amazon` EFA stack — do
NOT hostPath-mount `/opt/amazon/efa` (that shadowed the headers with an empty
dir in an earlier attempt).

```bash
git clone https://github.com/uccl-project/uccl.git
cd uccl/ep
pip install nanobind scikit-build-core "setuptools>=64" wheel build
USE_DMABUF=1 TORCH_CUDA_ARCH_LIST="9.0" python setup.py bdist_wheel
```

Build Summary must show `EFA Support: Yes`, `DMA-BUF Support: Yes`,
`Device Arch: 9.0`.

### 2a. rdma-core too old (`efadv.h has no member`)

UCCL `main`'s `rdma.cpp` uses newer EFA features:

```
error: 'struct efadv_qp_init_attr' has no member named 'sl'
error: 'EFADV_QP_FLAGS_UNSOLICITED_WRITE_RECV' was not declared in this scope
```

`UNSOLICITED_WRITE_RECV` landed in **rdma-core v52**; the `sl` field is an
efadv-specific QP attribute added around the same time. Ubuntu 24.04 (NGC base)
ships rdma-core 50, where **both the headers and the libraries are old**.

Upgrade the WHOLE rdma-core (headers AND libs), not just the header. Replacing
only `efadv.h` makes it compile but the new feature won't work at runtime if the
linked/loaded `libefa.so` / `libibverbs.so` are still v50 (missing symbols / the
new attribute is ignored). Also confirm the kernel-side EFA driver is recent
enough. Build a newer rdma-core and put its headers AND libs ahead of the OS ones:

```bash
apt-get install -y libnl-3-dev libnl-route-3-dev libudev-dev ninja-build pkg-config
git clone --depth 1 --branch v56.0 https://github.com/linux-rdma/rdma-core.git
cd rdma-core && bash build.sh
cp -a build/include/infiniband/efadv.h /usr/include/infiniband/efadv.h
cp -a build/lib/libefa.so* build/lib/libibverbs.so* /usr/lib/x86_64-linux-gnu/ && ldconfig
# at RUN time on the bench nodes, also prepend these libs via LD_LIBRARY_PATH.
```

(The current aws-efa-installer 1.49.0 also ships a new rdma-core userspace; that
works too. The point is: header + library + kernel driver must all be recent, not
the header alone.)

### 2b. Must pin `TORCH_CUDA_ARCH_LIST="9.0"`

Without it, the NGC image's multi-arch default (`7.5 8.0 8.6 9.0 10.0 12.0+PTX`)
is used, and UCCL's Hopper-only TMA/mbarrier code fails ptxas for `sm_75`:

```
ptxas ... error : Feature 'cp.async.bulk' requires .target sm_90 or higher
```

### 2c. bdist_wheel egg-metadata error → use pip install

`python setup.py bdist_wheel` fails at the very end with
`ValueError: Egg metadata expected ... but not found`. The compiled `ep.abi3.so`
is fine; install via `pip install . --no-build-isolation` instead, or just grab
the built `uccl/ep.abi3.so`.

Verify the fix:

```python
from uccl import ep
ep.can_register_rdma_gpu_buffer(0, 64 << 20)   # => True
dl, host_allocated = ep.get_rdma_buffer(64 << 20, 0)
# host_allocated == False  → GPU memory registered directly (dma-buf GPUDirect)
```

## 3. Distribute without rebuilding: stage on FSx

The working `uccl/ep.abi3.so`, the bench scripts, and the new rdma-core libs are
copied to `fsx-claim` at `/fsx/uccl-dmabuf/{uccl,bench,lib}`. The 2-node bench
job (`manifests/10-internode-bench.yaml`) then just:

```bash
export PYTHONPATH=/fsx/uccl-dmabuf:/workspace/ep_bench
export LD_LIBRARY_PATH=/fsx/uccl-dmabuf/lib   # newer libibverbs/libefa first
```

No per-node rebuild needed.

## 4. bench version must match the .so

`ep/bench/buffer.py` calls into `uccl.ep`; a `main` bench against a `v0.1.1`
wheel throws `get_rdma_buffer(): incompatible function arguments`. Keep the bench
scripts and the built module on the same commit.

## 5. Misc

- `FI_EFA_USE_DEVICE_RDMA` is a libfabric env; it does NOT affect UCCL's raw-verbs
  path (it matters for NCCL). No extra env is needed for the dma-buf path.
- 2 pods on distinct nodes via podAntiAffinity + a headless Service resolving
  rank0 by name for the torchrun rendezvous.
- `IPC_LOCK` capability is required (RDMA memlock).
