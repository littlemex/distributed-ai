#!/bin/bash
# Where in the step the CPU-cached lines sit: start (prefix) vs end (suffix) of the 1,024 cache-line step.
for r in 1 2; do
  for m in "prefix 256" "suffix 256" "prefix 512" "suffix 512" "prefix 768" "suffix 768" "all 1"; do
    set -- $m
    NCCLDIR=/root/nccl-s2 TMO=900 EXTRA="-x OFI_NCCL_PROTOCOL=RDMA -x NCCL_LLX_MODE=$1 -x NCCL_LLX_ARG=$2" /root/run.sh P2_$1_$2_$r all_reduce_perf -b 2M -e 4M -f 2 -g 8 -n 100 > /dev/null
    echo "r$r $1 $2 $(grep -E '^ +[0-9]+ +[0-9]+ +float +sum' /root/out/P2_$1_$2_$r.log | awk '{printf "%s=%sus ", $1, $6}')"
  done
done
echo PLACE2_DONE
