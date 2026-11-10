#!/bin/bash
# Collapse probability of the NCCL-shaped emulator (2 net + 2 SHM connections per GPU) and its controls.
export LD_LIBRARY_PATH=/opt/amazon/efa/lib:$LD_LIBRARY_PATH; cd /root
case_(){ # label env... -- args
  local label=$1; shift; local vals=""
  for r in $(seq 1 10); do v=$(env "$@" timeout 120 ./cliff7 $CARGS | sed -E 's/.*-> ([0-9.]+) us.*/\1/'); vals="$vals $v"; done
  python3 -I -c 'import sys; v=sorted(float(x) for x in sys.argv[2:]); n=len(v); c=sum(x>100 for x in v); print(f"{sys.argv[1]} collapsed={c}/{n} median={v[n//2]:.1f} min={v[0]:.1f} max={v[-1]:.1f} us/step")' $label $vals
}
CARGS="2 1024 500 4 2" case_ "2net+2shm_C1024" X=1
CARGS="2 0 500 4 2" case_ "2net+2shm_C0" X=1
CARGS="2 1024 500 4 2" case_ "2net+2shm_C1024_flush" CLIFF_FLUSH=1
CARGS="2 1024 500 2 2" case_ "2net_only_C1024" X=1
CARGS="2 1024 500 4 4" case_ "4net_C1024" X=1
CARGS="8 1024 300 4 2" case_ "8gpu_2net+2shm_C1024" X=1
CARGS="8 0 300 4 2" case_ "8gpu_2net+2shm_C0" X=1
echo C7_DONE
