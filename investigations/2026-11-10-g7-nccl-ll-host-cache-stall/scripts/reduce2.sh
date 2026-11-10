#!/bin/bash
# Shrink the single-node LL repro (SHM disabled -> every hop goes through EFA loopback) to find the
# smallest NCCL configuration that still collapses. Base NCCL vs patched NCCL.
H1=$(cut -d, -f1 /root/hosts)
L="-x OFI_NCCL_PROTOCOL=RDMA -x NCCL_SHM_DISABLE=1 -x NCCL_P2P_DISABLE=1 -x NCCL_PROTO=LL -x NCCL_ALGO=Ring"
one(){ # label gpus nch variant
  NCCLDIR=/root/nccl-$4 HOSTS=$H1 MPIOPT="-np 1" TMO=600 EXTRA="$L -x CUDA_VISIBLE_DEVICES=$2 -x NCCL_MIN_NCHANNELS=$3 -x NCCL_MAX_NCHANNELS=$3" \
    /root/run.sh RD_$1_$4 all_reduce_perf -b 512K -e 8M -f 4 -g $(echo $2 | tr , '\n' | wc -l) -n 30 > /dev/null
  echo "$1 gpus=$2 ch=$3 $4: $(grep -E '^ +[0-9]+ +[0-9]+ +float +sum' /root/out/RD_$1_$4.log | awk '{printf "%s=%sus ", $1, $6}') $(grep -c 'via NET' /root/out/RD_$1_$4.log)"
}
for r in 1 2; do for v in b; do
  one g4same_r$r 0,1,2,3 4 $v
  one g4split_r$r 0,1,4,5 4 $v
  one g3same_r$r 0,1,2 4 $v
  one g6split_r$r 0,1,2,4,5,6 4 $v
  one g8_r$r 0,1,2,3,4,5,6,7 4 $v
done; done
echo REDUCE2_DONE
