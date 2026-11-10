#!/bin/bash
# Adversarial re-test batch. Output: /root/T.txt
R=/root/run.sh; E="-x OFI_NCCL_PROTOCOL=RDMA"; H1=$(cut -d, -f1 /root/hosts)
o(){ echo "### $*"; }
o T1 reps base vs patch
for r in 1 2 3 4 5; do for v in b p; do NCCLDIR=/root/nccl-$v EXTRA="$E" $R T1_${v}_$r all_reduce_perf -b 512K -e 16M -f 2 -g 8 -n 50 | grep "us " | sed "s/^/$v r$r /"; done; done
o T2 tuning table
DBG=INFO SUBSYS=INIT,TUNING,NET,GRAPH EXTRA="$E" $R T2 all_reduce_perf -b 1M -e 1M -g 8 -n 5 | grep "us "
o T3 LL128 via ^LL
EXTRA="$E -x NCCL_PROTO=^LL" $R T3 all_reduce_perf -b 1M -e 64M -f 2 -g 8 -n 20 | grep "us "
o T4 GDR SYS default proto / Simple
EXTRA="$E -x NCCL_NET_GDR_LEVEL=SYS" $R T4a all_reduce_perf -b 1M -e 128M -f 2 -g 8 -n 20 | grep "us "
EXTRA="$E -x NCCL_NET_GDR_LEVEL=SYS -x NCCL_PROTO=Simple" $R T4b all_reduce_perf -b 16M -e 128M -f 2 -g 8 -n 20 | grep "us "
o T5 channels
for c in 1 2 4; do EXTRA="$E -x NCCL_MAX_NCHANNELS=$c" $R T5_$c all_reduce_perf -b 2M -e 2M -g 8 -n 50 | grep "us " | sed "s/^/ch$c /"; done
o T6 other collectives base vs patch
for coll in all_gather reduce_scatter broadcast reduce sendrecv alltoall; do for v in b p; do NCCLDIR=/root/nccl-$v EXTRA="$E" $R T6_${coll}_$v ${coll}_perf -b 64K -e 16M -f 4 -g 8 -n 20 | grep "us " | sed "s/^/$coll $v /"; done; done
o T7 threshold 0 vs 32K small sizes
for v in p t b; do NCCLDIR=/root/nccl-$v EXTRA="$E" $R T7_$v all_reduce_perf -b 8 -e 1M -f 4 -g 8 -n 200 | grep "us " | sed "s/^/$v /"; done
o T8 control scan vs scan+flush
for v in q f; do [ -f /root/nccl-$v/lib/libnccl.so.2 ] && NCCLDIR=/root/nccl-$v EXTRA="$E" $R T8_$v all_reduce_perf -b 1M -e 8M -f 2 -g 8 -n 50 | grep "us " | sed "s/^/$v /"; done
o T9 2GiB SENDRECV vs RDMA+Simple
EXTRA="-x OFI_NCCL_PROTOCOL=SENDRECV" $R T9a all_reduce_perf -b 2G -e 2G -g 8 -n 10 | grep "us "
EXTRA="$E -x NCCL_PROTO=Simple" $R T9b all_reduce_perf -b 2G -e 2G -g 8 -n 10 | grep "us "
o T10 without FI_EFA_USE_DEVICE_RDMA
DBG=INFO SUBSYS=INIT,NET EXTRA="$E -x FI_EFA_USE_DEVICE_RDMA=0" $R T10 all_reduce_perf -b 1M -e 8M -f 2 -g 8 -n 20 | grep -E "us |GDR|HMEM|NCCL_PROTO|exit"
o T11 single node LL loopback
for v in b p; do NCCLDIR=/root/nccl-$v HOSTS=$H1 MPIOPT="-np 1" EXTRA="$E -x NCCL_SHM_DISABLE=1 -x NCCL_PROTO=LL -x NCCL_ALGO=Ring -x NCCL_MIN_NCHANNELS=4 -x NCCL_MAX_NCHANNELS=4" $R T11_$v all_reduce_perf -b 256K -e 8M -f 2 -g 8 -n 20 | grep -E "us |exit" | sed "s/^/$v /"; done
o T13 one process per GPU 16 ranks
HOSTS="$(cut -d, -f1 /root/hosts):8,$(cut -d, -f2 /root/hosts):8" EXTRA="$E" MPIOPT="-np 16 -N 8" $R T13 all_reduce_perf -b 512K -e 16M -f 2 -g 1 -n 20 | grep -E "us |exit"
echo TESTS_DONE
