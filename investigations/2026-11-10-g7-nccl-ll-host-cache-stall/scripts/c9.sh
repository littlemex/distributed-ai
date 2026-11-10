#!/bin/bash
# cliff9 across two real nodes: share of slow steps (>100 us) and tail latency per condition, 6 runs each.
L="-x LD_LIBRARY_PATH=/opt/amazon/efa/lib:/opt/amazon/openmpi/lib:/usr/local/cuda/lib64"
for r in 1 2 3 4 5 6; do
  for m in "C1024 1024 " "C0 0 " "flush 1024 -x CLIFF_FLUSH=1" "noread 1024 -x CLIFF_SHM_NOREAD=1"; do
    set -- $m; lab=$1; C=$2; shift 2
    TMO=300 EXTRA="$L $*" /root/run.sh C9_${lab}_$r cliff9 $C 500 > /dev/null
    echo "r$r $lab $(grep cliff9 /root/out/C9_${lab}_$r.log | sed -E 's/.*-> //')"
  done
done
echo C9_DONE
