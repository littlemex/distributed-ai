#!/bin/bash
# Slowdown vs number of CPU-cached cache lines per step (proxy reads 1 of every K cache lines after the GPU is done).
for r in 1 2; do
  for K in 1 2 4 16 64 100000; do
    NCCLDIR=/root/nccl-r TMO=900 EXTRA="-x OFI_NCCL_PROTOCOL=RDMA -x NCCL_LLSCAN_STRIDE_CL=$K" /root/run.sh ST_${K}_$r all_reduce_perf -b 1M -e 4M -f 2 -g 8 -n 100 > /dev/null
    echo "r$r K=$K $(grep -E '^ +[0-9]+ +[0-9]+ +float +sum' /root/out/ST_${K}_$r.log | awk '{printf "%s=%sus ", $1, $6}')"
  done
  NCCLDIR=/root/nccl-p EXTRA="-x OFI_NCCL_PROTOCOL=RDMA" /root/run.sh ST_p_$r all_reduce_perf -b 1M -e 4M -f 2 -g 8 -n 100 > /dev/null
  echo "r$r p(no read) $(grep -E '^ +[0-9]+ +[0-9]+ +float +sum' /root/out/ST_p_$r.log | awk '{printf "%s=%sus ", $1, $6}')"
done
echo STRIDE_DONE
