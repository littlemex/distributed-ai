#!/bin/bash
# usage: run.sh <label> <binary> <args...> ; extra env via EXTRA="-x A=1 -x B=2"
. /etc/g7ll.env
L=$1; shift; B=$1; shift; NL=${NCCLDIR:-/root/nccl-b}/lib; export LD_LIBRARY_PATH=$NL:$LD_LIBRARY_PATH LD_PRELOAD=$NL/libnccl.so.2
mkdir -p /root/out
timeout ${TMO:-400} mpirun --allow-run-as-root ${MPIOPT:--np 2 -N 1} -H ${HOSTS:-$(cat /root/hosts)} --bind-to none \
  --mca plm_rsh_args "-p 2222" --mca btl tcp,self --mca btl_tcp_if_exclude lo,docker0 --mca oob_tcp_if_exclude lo \
  -x PATH -x LD_LIBRARY_PATH -x LD_PRELOAD -x FI_PROVIDER=efa -x FI_EFA_USE_DEVICE_RDMA=1 -x NCCL_NET_GDR_LEVEL=2 \
  -x NCCL_SOCKET_IFNAME=eth0 -x NCCL_DEBUG=${DBG:-WARN} -x NCCL_DEBUG_SUBSYS=${SUBSYS:-INIT,ENV,TUNING,NET} $EXTRA \
  /root/nt-b/$B "$@" > /root/out/$L.log 2>&1
echo "exit=$?"
grep -E "NCCL version|Using transport protocol|Internode latency|NCCL_PROTO set|OFI_NCCL_PROTOCOL|NET/OFI.*plugin|Selected provider" /root/out/$L.log | sort | uniq -c | head -12
grep -E "^ +[0-9]+ +[0-9]+ +float +sum" /root/out/$L.log | awk '{printf "%10s %10s us %8s GB/s wrong=%s\n",$1,$6,$8,$9}'
