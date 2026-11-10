#!/bin/bash
export LD_LIBRARY_PATH=/opt/amazon/efa/lib:$LD_LIBRARY_PATH; cd /root
case_(){ local label=$1; shift; local vals=""; for r in $(seq 1 10); do v=$(env "$@" timeout 120 ./cliff7 $CARGS | sed -E 's/.*-> ([0-9.]+) us.*/\1/'); vals="$vals $v"; done
  python3 -I -c 'import sys; v=sorted(float(x) for x in sys.argv[2:]); n=len(v); c=sum(x>100 for x in v); print(f"{sys.argv[1]} collapsed={c}/{n} median={v[n//2]:.1f} min={v[0]:.1f} max={v[-1]:.1f} us/step")' $label $vals; }
CARGS="2 1024 500 4 2" case_ "2net+2shm_read_by_next_GPU" CLIFF_SHM_NOREAD=0
CARGS="2 1024 500 4 2" case_ "2net+2shm_nobody_reads" CLIFF_SHM_NOREAD=1
CARGS="2 1024 500 3 2" case_ "2net+1shm_read_by_next_GPU" CLIFF_SHM_NOREAD=0
CARGS="2 1024 500 3 2" case_ "2net+1shm_nobody_reads" CLIFF_SHM_NOREAD=1
CARGS="2 1024 500 3 1" case_ "1net+2shm_read_by_next_GPU" CLIFF_SHM_NOREAD=0
echo C7B_DONE
