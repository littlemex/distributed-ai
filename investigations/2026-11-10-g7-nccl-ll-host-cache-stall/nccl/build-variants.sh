#!/bin/bash
# Variants: b base, p patch(thr32K), q patch but proxy scans, t patch thr0, f = q + clflushopt after scan.
G="-gencode=arch=compute_120,code=sm_120"
mk(){ v=$1; cp -r /opt/nccl /root/nccl-$v-src; cd /root/nccl-$v-src && rm -rf build
  [ $v != b ] && patch -p1 < /root/ll-defer.patch >/dev/null
  [ $v = q -o $v = f ] && sed -i "s/} else if (p == NCCL_PROTO_LL \&\& !llReady) {/} else if (p == NCCL_PROTO_LL) {/" src/transport/net.cc
  [ $v = f ] && python3 -I /root/mkf.py src/transport/net.cc
  [ $v = t ] && sed -i "s/#define NCCL_LL_DEFER_SIZE_MIN (32\*1024)/#define NCCL_LL_DEFER_SIZE_MIN 0/" src/include/device.h
  make -j 38 src.build NVCC_GENCODE="$G" BUILDDIR=/root/nccl-$v > /root/nccl-$v.log 2>&1 && echo ok > /root/nccl-$v.done; }
for v in b p q t f; do mk $v & done
cp -r /opt/nccl-tests /root/nt-src; cd /root/nt-src && make -j 32 MPI=1 MPI_HOME=/opt/amazon/openmpi NCCL_HOME=/opt/nccl/build CUDA_HOME=/usr/local/cuda NVCC_GENCODE="$G" BUILDDIR=/root/nt-b > /root/nt-b.log 2>&1 && echo ok > /root/nt-b.done
wait; echo ALLDONE > /root/all.done
