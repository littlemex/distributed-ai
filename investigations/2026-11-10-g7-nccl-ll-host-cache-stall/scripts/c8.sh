#!/bin/bash
# EFA removed: net connections copied by the proxy CPU. Does the collapse need the NIC?
export LD_LIBRARY_PATH=/opt/amazon/efa/lib:$LD_LIBRARY_PATH; cd /root
case_(){ local label=$1; shift; local vals=""; for r in $(seq 1 10); do v=$(env "$@" timeout 180 ./cliff8 $CARGS | sed -E 's/.*-> ([0-9.]+) us.*/\1/'); vals="$vals $v"; done
  echo "RAW $label:$vals" >> /root/c8.raw
  python3 -I -c 'import sys; v=sorted(float(x) for x in sys.argv[2:]); n=len(v); c=sum(x>100 for x in v); print(f"{sys.argv[1]} collapsed={c}/{n} median={v[n//2]:.1f} min={v[0]:.1f} max={v[-1]:.1f} us/step")' "$label" $vals; }
CARGS="2 1024 500 4 2" case_ "efa_2gpu" X=1
CARGS="2 1024 500 4 2" case_ "noefa_2gpu" CLIFF_NOEFA=1
CARGS="2 1024 500 4 2" case_ "noefa_flush_2gpu" CLIFF_NOEFA=1 CLIFF_NOEFA_FLUSH=1
CARGS="2 1024 500 4 2" case_ "noefa_noread_2gpu" CLIFF_NOEFA=1 CLIFF_SHM_NOREAD=1
CARGS="8 1024 300 4 2" case_ "noefa_8gpu" CLIFF_NOEFA=1
CARGS="8 1024 300 4 2" case_ "noefa_flush_8gpu" CLIFF_NOEFA=1 CLIFF_NOEFA_FLUSH=1
echo C8_DONE
