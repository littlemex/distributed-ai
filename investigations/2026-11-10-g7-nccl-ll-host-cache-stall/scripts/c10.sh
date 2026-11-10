#!/bin/bash
# cliff10 (one process per GPU, 2 real nodes): share of slow steps and tail latency, 6 runs per condition.
L="-x LD_LIBRARY_PATH=/opt/amazon/efa/lib:/opt/amazon/openmpi/lib:/usr/local/cuda/lib64"
H="$(cut -d, -f1 /root/hosts):2,$(cut -d, -f2 /root/hosts):2"
for r in 1 2 3 4 5 6; do
  for m in "C1024 1024 " "C0 0 " "flush 1024 -x CLIFF_FLUSH=1" "noread 1024 -x CLIFF_SHM_NOREAD=1"; do
    set -- $m; lab=$1; C=$2; shift 2
    TMO=300 HOSTS=$H MPIOPT="-np 4 -N 2" EXTRA="$L $*" /root/run.sh C10_${lab}_$r cliff10 $C 500 > /dev/null
    echo "r$r $lab $(grep '\[cliff10\]' /root/out/C10_${lab}_$r.log | sed -E 's/.*-> //')"
  done
done
echo C10_DONE
