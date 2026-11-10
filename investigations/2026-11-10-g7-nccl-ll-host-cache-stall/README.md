# NCCL LL all-reduce stalls on g7.48xlarge: CPU-cached copies of host-memory send buffers

On two g7.48xlarge nodes, NCCL 2.30.4 with aws-ofi-nccl (RDMA protocol) runs 1-8 MiB all-reduce 20-40x slower than its own cost model predicts, while smaller and larger sizes are normal. In this size range NCCL picks the LL protocol. g7.48xlarge does not use GPUDirect RDMA (GPU and EFA are not under a common PCIe switch), so the LL send buffer lives in pinned host memory, and NCCL's network proxy thread reads every LL line of each step on the CPU before handing the buffer to EFA. This directory holds the code used to measure the effect, to change NCCL so that the proxy no longer reads the lines, and to reproduce the stall without NCCL.

## Results

| # | Check | Result |
|---|---|---|
| R1 | 2 nodes, 16 ranks, `all_reduce_perf`, `OFI_NCCL_PROTOCOL=RDMA` | 2 MiB takes 13.6-16.0 ms (5 runs). `NCCL_PROTO=Simple` gives 0.84 ms. NCCL's own estimate is 0.39 ms |
| R2 | NCCL change: the GPU publishes the step size after writing the lines, and the proxy skips the flag scan (`nccl/ll-defer.patch`) | 2 MiB takes 0.379-0.381 ms (5 runs). all_gather, reduce_scatter, broadcast and reduce are fixed as well; sendrecv and alltoall are unchanged |
| R3 | Same GPU side as R2, but the proxy reads every line once after the step is complete | 2 MiB median 9.2 ms. Adding `clflushopt` after the read gives 1.36 ms; `cldemote` gives 1.14 ms |
| R4 | Proxy reads only a contiguous run of N cache lines per 1,024-line step (2 runs each) | N = 256 or 512: 0.38-0.58 ms. N = 768: 2.2-7.5 ms. N = 1,024: 9.6-12.1 ms. Start or end of the step made no visible difference |
| R5 | NCCL-free program `cuda/cliff8.cu`, one node, EFA loopback, each GPU with 2 "net" streams (CPU reads the lines, EFA writes the slot to the next GPU) and 2 "SHM" streams (the next GPU polls the slot), 10 runs | 10/10 and 9/10 runs stall at about 290-320 us per step. On another host 3/10 |
| R6 | Same program, one element removed at a time, 10 runs each | 0/10 when the CPU does not read, when it reads and then flushes, when the CPU copies the slot instead of EFA, when EFA sends a different buffer at the same pace, when nobody reads the SHM slots, and with 2 or 3 streams per GPU |
| R7 | Two real nodes (`cuda/cliff9.cu`, one process per node; `cuda/cliff10.cu`, one process per GPU), 6 runs each, per-step timing | With cached copies, 4.7-10.8% (cliff9) and 8.2-47.2% (cliff10) of steps exceed 100 us, p99 409-467 us. Without the CPU read or with a flush: 0-0.1% |

The measured condition: GPU writes LL lines into pinned host memory; the CPU reads those lines and keeps cached copies; EFA reads the same slot; the GPU later overwrites it; and one GPU has several such write streams at once. In the one-node loopback setup, removing any one of these made the stall disappear in 10 out of 10 runs. The mechanism inside the CPU and the PCIe path is not established; it would need uncore counters, which are not readable from inside the g7 VM.

## Environment

| Item | Value |
|---|---|
| Instances | 2 x g7.48xlarge (2 sockets Intel Xeon 6975P-C, 8 x RTX PRO 4500 Blackwell, 2 EFA devices) on EKS with Karpenter |
| Image | `public.ecr.aws/hpc-cloud/nccl-tests:cuda13.0.2-efa1.48.0-ofiv1.19.0-ncclv2.30.4-1-testsv2.18.3` |
| NCCL | v2.30.4-1 (`1933fdd6`), rebuilt for sm_120 |
| aws-ofi-nccl | v1.19.0, libfabric 2.4.0amzn3.0 |
| GPU driver | 595.91.07 |

The public image's NCCL and nccl-tests contain no sm_120 code, so on g7 the first collective fails with `named symbol not found`. `nccl/build-variants.sh` rebuilds NCCL and nccl-tests with `-gencode=arch=compute_120,code=sm_120`. The image sets `LD_PRELOAD` to its own NCCL, so `scripts/run.sh` overrides `LD_PRELOAD` as well as `LD_LIBRARY_PATH`.

## Reproduce

The pods need both EFA devices. Karpenter only accepts `interface` and `efa-only` interface types, so the node class must list an EFA-only interface on each network card (`k8s/karpenter-network-interfaces.yaml`). `k8s/two-node-pods.yaml` starts one pod per node with all 8 GPUs and both EFA devices, an `sshd` on port 2222 for `mpirun`, and a large `/dev/shm`. The node selector `node-role: g7ll` must match your node pool.

```bash
export NS=g7ll
ssh-keygen -q -t ed25519 -N '' -f ./id
kubectl create namespace $NS
kubectl -n $NS create secret generic g7ll-ssh --from-file=id --from-file=id.pub
kubectl apply -f k8s/two-node-pods.yaml
kubectl -n $NS wait --for=condition=Ready pod -l app=g7ll --timeout=30m
```

Copy the files of `nccl/`, `scripts/` and `cuda/` flat into `/root` of both pods and build the NCCL variants there. `build-variants.sh` builds `b` (unchanged), `p` (`ll-defer.patch`), `q` (patch, proxy still scans), `t` (patch with threshold 0) and `f` (`q` plus `clflushopt`), and nccl-tests.

```bash
export NS=g7ll
for P in $(kubectl -n $NS get pod -l app=g7ll -o name); do
  for f in nccl/* scripts/* cuda/*; do kubectl -n $NS cp "$f" "${P#pod/}:/root/$(basename "$f")"; done
  kubectl -n $NS exec $P -- bash -c 'cd /root && chmod +x *.sh && ./build-variants.sh > build.out 2>&1; cat /root/all.done'
done
```

Run the all-reduce comparison from the first pod. `run.sh` reads the two pod IPs from `/root/hosts`; `NCCLDIR` selects the variant.

```bash
export NS=g7ll
P0=$(kubectl -n $NS get pod -l batch.kubernetes.io/job-completion-index=0 -o name)
kubectl -n $NS exec $P0 -- bash -c 'echo "$(getent hosts g7ll-0.g7ll | cut -d" " -f1),$(getent hosts g7ll-1.g7ll | cut -d" " -f1)" > /root/hosts'
kubectl -n $NS exec $P0 -- bash -c 'for v in b p; do NCCLDIR=/root/nccl-$v EXTRA="-x OFI_NCCL_PROTOCOL=RDMA" /root/run.sh AR_$v all_reduce_perf -b 512K -e 16M -f 2 -g 8 -n 50; done'
```

The NCCL-free programs build with `nvcc` against libfabric (and MPI for the two-node versions):

```bash
nvcc -O2 -arch=sm_120 -Xcompiler -mclflushopt -I/opt/amazon/efa/include -L/opt/amazon/efa/lib -lfabric -o cliff8 cuda/cliff8.cu
nvcc -O2 -arch=sm_120 -I/opt/amazon/efa/include -I/opt/amazon/openmpi/include -L/opt/amazon/efa/lib -L/opt/amazon/openmpi/lib -lfabric -lmpi -o cliff10 cuda/cliff10.cu
```

`cliff8 <ngpu> <cached lines per step> <steps> <streams per GPU> <net streams per GPU>`; for example `./cliff8 2 1024 500 4 2` is the R5 configuration. Controls are environment variables: `CLIFF_FLUSH=1`, `CLIFF_SHM_NOREAD=1`, `CLIFF_NOEFA=1`, `CLIFF_EFA_DUMMY=1`, `CLIFF_CACHED_CONNS=<n>`. `scripts/c8.sh`, `scripts/c8b.sh` and `scripts/c7c.sh` run each condition 10 times. `cliff10` runs with `mpirun -np 4 -N 2` (`scripts/c10.sh`); it ends with `_exit` because `MPI_Finalize` does not return while efa-direct endpoints are open.

## Directory

```
2026-11-10-g7-nccl-ll-host-cache-stall/
├── nccl/
│   ├── ll-defer.patch          GPU publishes the LL step size after writing; proxy skips the flag scan
│   ├── build-variants.sh       builds NCCL variants b, p, q, t, f and nccl-tests for sm_120
│   └── mk*.py                  source edits for the diagnostic variants (scan counters, re-scan backoff,
│                               read patterns, flush, LL128 flush, receiver poll backoff)
├── cuda/
│   ├── cliff.cu ... cliff7.cu  NCCL-free LL send-side models, from one stream to N-GPU rings with SHM streams
│   ├── cliff8.cu               one-node model with the EFA / CPU-copy / dummy-EFA controls (R5, R6)
│   ├── cliff9.cu, cliff10.cu   two-node models, one process per node and one process per GPU (R7)
│   ├── hostwrite*.cu           GPU store bandwidth into host memory the CPU has just read
│   ├── rdlat.cu                latency of a GPU's own host reads while its writes are in flight
│   └── opseries.cu             times every all-reduce of a long run
├── scripts/                    mpirun wrapper and the batches that produced the numbers above
└── k8s/                        two-node pods and the EC2NodeClass network-interface fragment
```

## Limits

- One instance type, one region, three pairs of hosts, the versions above.
- The stall probability varies by host (3/10 to 10/10 in the same configuration).
- The NCCL-free element-by-element controls (R6) ran on one node with EFA loopback; on two nodes only the presence of the CPU copies was varied.
- In the dummy-EFA control the receive slot is written by the CPU instead of EFA, so "EFA reads the cached lines" and "EFA writes the receive slot" are not separated.
- `clflushopt`, `cldemote`, re-scan backoff and `NCCL_LL_BUFFSIZE` variants are diagnostics, not proposed fixes.
