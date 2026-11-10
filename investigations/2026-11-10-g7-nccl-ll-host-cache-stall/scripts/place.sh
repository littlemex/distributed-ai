#!/bin/bash
# Same NCCL (variant s), different patterns of CPU-cached lines in the LL send buffer. 2 MiB all-reduce.
for r in 1 2; do
  for m in "all 1" "none 1" "stride 2" "stride 4" "prefix 256" "prefix 512" "slotmod 4" "chan 2" "demote 1"; do
    set -- $m
    NCCLDIR=/root/nccl-s TMO=900 EXTRA="-x OFI_NCCL_PROTOCOL=RDMA -x NCCL_LLX_MODE=$1 -x NCCL_LLX_ARG=$2" /root/run.sh PL_$1_$2_$r all_reduce_perf -b 1M -e 4M -f 2 -g 8 -n 100 > /dev/null
    echo "r$r $1 $2 $(grep -E '^ +[0-9]+ +[0-9]+ +float +sum' /root/out/PL_$1_$2_$r.log | awk '{printf "%s=%sus ", $1, $6}')"
  done
done
echo PLACE_DONE
