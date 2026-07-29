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
  is not loaded — and on EFA that is irrelevant anyway** (causal note below).
- **Why `ibv_reg_mr` on a GPU buffer fails here.** Registering *device* memory as
  an RDMA MR through the classic `ibv_reg_mr` needs a kernel **peer-memory
  bridge**: something has to pin GPU pages and expose them to the NIC. On the
  Mellanox/IB stack that bridge is exactly what `nvidia_peermem` (the legacy
  `ib_peer_mem` client) provides. **EFA does not implement the peer-memory API at
  all**, so `ibv_reg_mr` on GPU memory returns `EOPNOTSUPP` here *regardless* of
  whether `nvidia_peermem` is loaded — loading peermem would not help on EFA. (So
  the failure is not "peermem missing"; it is "this code path is the wrong one for
  EFA".)
- **Why NCCL is fine, and what the right path is.** aws-ofi-nccl/libfabric
  register GPU memory via **dma-buf** (`ibv_reg_dmabuf_mr`), *not* the peer-memory
  bridge. dma-buf is a generic kernel buffer-sharing mechanism, independent of
  `nvidia_peermem`: the GPU driver *exports* the buffer as a dma-buf fd and verbs
  *imports* it. That is why NCCL gets GPUDirect over EFA with peermem absent — and
  why UCCL must be built to use the same path.
- The **prebuilt wheel uses the legacy `ibv_reg_mr` path**, so it hits the
  `EOPNOTSUPP` above. The dma-buf path in `ep/src/rdma.cpp` (`reg_mr_gpu_dmabuf`,
  "avoids nvidia_peermem dependency") is guarded by `#ifdef USE_DMABUF`, and the
  wheel is built WITHOUT it. Confirm the failure crisply:

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

### 2c. Both `bdist_wheel` AND `pip install .` exit non-zero — tolerate it, verify the .so directly

UCCL's `ep/setup.py` is not a standards-based build backend, so its packaging
wrapper trips at the very end **after** the real build has already succeeded:

- `python setup.py bdist_wheel` → `ValueError: Egg metadata expected at
  ...ep-*.egg-info but not found`.
- `pip install . --no-build-isolation --no-deps` → the same egg-metadata error,
  then `error: option --all not recognized` (from a trailing `setup.py clean
  --all`).

In both cases setup.py has **already** printed `Installation complete. Module
installed as: .../uccl/ep.abi3.so`, and the `.so` is built and installed. So do
NOT trust pip's exit code — tolerate the non-zero exit and verify the module
directly:

```bash
USE_DMABUF=1 TORCH_CUDA_ARCH_LIST="9.0" \
  pip install . --no-build-isolation --no-deps --root-user-action=ignore || \
  echo "pip returned non-zero (expected post-install step); verifying .so directly"
python -c "from uccl import ep; assert ep.can_register_rdma_gpu_buffer(0, 64<<20); print('OK')"
```

### 2d. `uccl` is an implicit namespace package — `uccl.__file__` is None

There is no `uccl/__init__.py`, so `import uccl; uccl.__file__` is `None` and you
cannot locate the install dir that way. Derive it from the installed *submodule*
when staging the `.so` onto FSx:

```bash
SP="$(python -c 'import uccl.ep as m, os; print(os.path.dirname(m.__file__))')"
cp -a "$SP"/ep*.so /fsx/uccl-dmabuf/uccl/
[ -f /fsx/uccl-dmabuf/uccl/__init__.py ] || echo "" > /fsx/uccl-dmabuf/uccl/__init__.py
```

The staged copy gets an empty `__init__.py` so `PYTHONPATH=/fsx/uccl-dmabuf`
resolves `uccl.ep` as a normal package on the bench nodes.

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
