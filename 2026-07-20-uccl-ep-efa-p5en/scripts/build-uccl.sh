#!/usr/bin/env bash
# build-uccl.sh — build UCCL-EP with USE_DMABUF=1 and stage it on FSx.
#
# Run this INSIDE the build pod (manifests/01-build-probe.yaml), i.e. an NGC
# PyTorch 25.01 container on a p5en node with /fsx mounted. It is not an SSH
# runner — you exec into the pod and run this once:
#
#   kubectl apply -f manifests/01-build-probe.yaml
#   kubectl exec -it uccl-build -- bash /fsx/.../build-uccl.sh   # or paste it
#
# Why USE_DMABUF: the PyPI wheel registers GPU memory via ibv_reg_mr (needs
# nvidia_peermem). On a peermem-less EFA node that fails with EOPNOTSUPP. The
# USE_DMABUF build uses ibv_reg_dmabuf_mr and needs no peermem. See docs/GOTCHAS.md.
set -euo pipefail

STAGE=/fsx/uccl-dmabuf
mkdir -p "$STAGE"/{uccl,bench,lib}

echo "[build] deps"
apt-get update >/dev/null
apt-get install -y libnl-3-dev libnl-route-3-dev libudev-dev ninja-build pkg-config \
  pciutils environment-modules tcl >/dev/null
pip install --root-user-action=ignore nanobind scikit-build-core "setuptools>=64" wheel build >/dev/null

echo "[build] newer rdma-core (v56) for the updated efadv.h (UNSOLICITED_WRITE_RECV, sl)"
cd /tmp && rm -rf rdma-core
git clone --depth 1 --branch v56.0 https://github.com/linux-rdma/rdma-core.git
cd rdma-core && bash build.sh >/dev/null
cp -a build/include/infiniband/efadv.h /usr/include/infiniband/efadv.h
cp -a build/lib/libefa.so* build/lib/libibverbs.so* /usr/lib/x86_64-linux-gnu/
ldconfig
grep -q UNSOLICITED_WRITE_RECV /usr/include/infiniband/efadv.h && echo "  efadv.h updated"

echo "[build] UCCL main, USE_DMABUF=1, sm_90 only"
cd /tmp && rm -rf uccl
git clone --depth 1 https://github.com/uccl-project/uccl.git
cd uccl/ep
# NOTE: this pip install exits non-zero at the very end with
#   ValueError: Egg metadata expected at ...ep-*.egg-info but not found
#   error: option --all not recognized   (setup.py clean --all)
# but that is AFTER setup.py has already run its own installer and printed
# "Installation complete. Module installed as: .../uccl/ep.abi3.so". The .so IS
# built and installed; only pip's wheel-metadata/clean wrapper trips (UCCL's
# setup.py is not a standards-based build backend). So we tolerate the failure
# and verify the .so directly below instead of trusting pip's exit code.
USE_DMABUF=1 TORCH_CUDA_ARCH_LIST="9.0" pip install . --no-build-isolation --no-deps --root-user-action=ignore || \
  echo "[build] pip returned non-zero (expected: post-install wheel-metadata step); verifying .so directly"

echo "[build] verify GPUDirect (dma-buf) works without peermem"
python -c "from uccl import ep; assert ep.can_register_rdma_gpu_buffer(0, 64<<20), 'GPU MR reg still fails'; print('  can_register_rdma_gpu_buffer: True')"

echo "[build] stage artifacts on FSx"
# `uccl` is an implicit namespace package (no __init__.py) so uccl.__file__ is
# None; derive the install dir from the installed submodule instead.
SP="$(python -c 'import uccl.ep as m, os; print(os.path.dirname(m.__file__))')"
cp -a "$SP"/ep*.so "$STAGE/uccl/"
[ -f "$STAGE/uccl/__init__.py" ] || echo "" > "$STAGE/uccl/__init__.py"
cp -a bench/{test_intranode.py,test_internode.py,test_low_latency.py,utils.py,buffer.py} "$STAGE/bench/"
cp -a /usr/lib/x86_64-linux-gnu/libibverbs.so* /usr/lib/x86_64-linux-gnu/libefa.so* "$STAGE/lib/"
cp -a /tmp/rdma-core/build/lib/libefa-rdmav*.so "$STAGE/lib/" 2>/dev/null || true

echo "[build] done. staged at $STAGE"
ls -R "$STAGE"
