#!/bin/bash
# Dose-response: proxy LL re-scan backoff vs all-reduce time and re-scans per step.
for r in 1 2; do for bo in 0 1000 5000 20000 100000; do
  NCCLDIR=/root/nccl-d TMO=900 EXTRA="-x OFI_NCCL_PROTOCOL=RDMA -x NCCL_LLSCAN_BACKOFF_NS=$bo" /root/run.sh DO_${bo}_$r all_reduce_perf -b 2M -e 2M -g 8 -n 200 > /dev/null
  t=$(grep -E "^ +[0-9]+ +[0-9]+ +float" /root/out/DO_${bo}_$r.log | awk '{print $6}')
  sc=$(grep -h LLSCAN /root/out/DO_${bo}_$r.log | awk '{t[$2]=$4" "$5} END{for(k in t) print t[k]}' | sed 's/scans\/step=//; s/lines\/step=//' | sort -n | awk '{a[NR]=$1; l[NR]=$2} END{printf "scans/step min=%s max=%s | lines/step max=%s", a[1], a[NR], l[NR]}')
  echo "r$r backoff=${bo}ns time=${t}us $sc"
done; done
echo DOSE_DONE
