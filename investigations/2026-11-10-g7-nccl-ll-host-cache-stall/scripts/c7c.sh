#!/bin/bash
# Confirmation set for the NCCL-free repro (cliff7). MODE=key: 2-GPU key cases; MODE=g8: 8-GPU cases.
export LD_LIBRARY_PATH=/opt/amazon/efa/lib:$LD_LIBRARY_PATH; cd /root
case_(){ local label=$1; shift; local vals=""; for r in $(seq 1 10); do v=$(env "$@" timeout 180 ./cliff7 $CARGS | sed -E 's/.*-> ([0-9.]+) us.*/\1/'); vals="$vals $v"; done
  echo "RAW $label:$vals" >> /root/c7c.raw
  python3 -I -c 'import sys; v=sorted(float(x) for x in sys.argv[2:]); n=len(v); c=sum(x>100 for x in v); print(f"{sys.argv[1]} collapsed={c}/{n} median={v[n//2]:.1f} min={v[0]:.1f} max={v[-1]:.1f} us/step")' "$label" $vals; }
if [ "$MODE" = key ]; then
  CARGS="2 1024 500 4 2" case_ "host=$(hostname)_2gpu_2net+2shm_read" CLIFF_SHM_NOREAD=0
  CARGS="2 1024 500 4 2" case_ "host=$(hostname)_2gpu_2net+2shm_noread" CLIFF_SHM_NOREAD=1
  CARGS="2 0 500 4 2" case_ "host=$(hostname)_2gpu_2net+2shm_C0" CLIFF_SHM_NOREAD=0
  CARGS="2 1024 500 4 2" case_ "host=$(hostname)_2gpu_2net+2shm_flush" CLIFF_FLUSH=1
else
  CARGS="8 1024 300 4 2" case_ "host=$(hostname)_8gpu_2net+2shm_read" CLIFF_SHM_NOREAD=0
  CARGS="8 1024 300 4 2" case_ "host=$(hostname)_8gpu_2net+2shm_noread" CLIFF_SHM_NOREAD=1
  CARGS="8 1024 300 4 2" case_ "host=$(hostname)_8gpu_2net+2shm_flush" CLIFF_FLUSH=1
  CARGS="8 1024 300 3 2" case_ "host=$(hostname)_8gpu_2net+1shm_read" CLIFF_SHM_NOREAD=0
fi
echo C7C_DONE
