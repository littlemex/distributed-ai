# GPUDirect Storage reads from FSx for Lustre over EFA, with KvikIO and gdsio

AWS documents GPUDirect Storage (GDS) for FSx for Lustre file systems created with EFA, read from P5, P5e, P5en, P6-B200 and P6-B300 instances ([FSx for Lustre: EFA-enabled file systems](https://docs.aws.amazon.com/fsx/latest/LustreGuide/efa-file-systems.html)). In that path the file servers move file data with RDMA over EFA straight into GPU memory, instead of into host memory first. This investigation checks, on a p5e.48xlarge, that reads really take that path, and measures what it buys over staging through host memory.

The same instance's local instance store is measured too, as a control. On p4d.24xlarge the instance store and EBS NVMe devices refused every read whose destination was GPU memory (NVMe status `Invalid Field in Command`), with both the nvidia-fs path and the kernel P2PDMA path, while an EFA device on the same PCIe bus wrote GPU memory directly.

## What is measured

| # | Check | How a result is told apart |
|---|---|---|
| 1 | The GDS stack is in place: nvidia-fs loaded and at least 2.24.2, `gdscheck -p` with /fsx mounted | `stack/` |
| 2 | gdsio on /fsx: GPU-direct with cuFile's compat fallback disabled (`allow_compat_mode=false`), GPU-direct with the default config, cuFile forced to compat (`CUFILE_FORCE_COMPAT_MODE=true`), and gdsio's own CPU staging (`-x 2`), over threads, IO sizes, one GPU and eight GPUs | A strict read that succeeds is direct. Per cell: GiB/s, CPU cores busy, the nvidia-fs read counters and the EFA hardware counters (RDMA bytes) before and after |
| 3 | KvikIO on /fsx with `KVIKIO_COMPAT_MODE=off` and cuFile strict (must be direct), and with `KVIKIO_COMPAT_MODE=on` (KvikIO's own POSIX bounce) | GB/s per GPU, process CPU seconds, KvikIO's compat decision, `gds_stats` taken on each worker before it exits |
| 4 | The same strict and compat reads from the local instance store RAID0 | Whether the Nitro NVMe on this instance accepts a GPU destination; the kernel log is kept |

Why counters and not only throughput: a read that falls back to host memory still succeeds, and at these sizes the fallback can be nearly as fast. What differs is where the bytes went (EFA RDMA counters rise, nvidia-fs counts the read) and how much CPU it took.

## Files

```
2026-11-10-gds-kvikio-fsx-lustre-efa/
├── scripts/
│   ├── counters.py               nvidia-fs, EFA hardware and CPU counters, sampled around each run
│   ├── make_cufile_variants.py   default.json and strict.json from the stock cufile.json
│   ├── gdsio_sweep.py            gdsio over a matrix, one process per GPU, JSON line per cell
│   ├── kvikio_read.py            KvikIO reads, one process per GPU, JSON line per run
│   └── cufile_version_matrix.sh  gdsio and KvikIO with each libcufile through LD_PRELOAD
├── tasks/
│   ├── 10-gds-stack.json         nvidia-fs, cuFile configs, gdscheck, KvikIO venv (pinned)
│   ├── 20-gdsio-fsx.json         test files on /fsx and the gdsio matrix
│   ├── 30-kvikio-fsx.json        KvikIO strict and compat
│   ├── 40-local-nvme-control.json  the same reads from /local
│   ├── 50-cufile-version.json      the same strict read with every libcufile on the host
│   └── 90-harness-smoke.json       one cell of each harness on any single-GPU instance
└── results/                      filled by ../2026-11-10-p5e-single-node-campaign/4.pull-results.sh
```

## Environment

| Item | Value |
|---|---|
| Instance | p5e.48xlarge, sa-east-1c, Capacity Block |
| AMI | Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04) 20261106, `ami-0169a766f567bc432` (Lustre client 2.15.6, EFA and the GDS tools preinstalled; nvidia-fs is built from source, see below) |
| File system | FSx for Lustre 2.15, Persistent 2, SSD, 4.8 TiB, 1000 MB/s/TiB, EFA enabled, automatic metadata configuration |
| Lustre client | AWS `configure-efa-fsx-lustre-client` script with `--optimized-for-gds` (its default on p5e is 8 EFA interfaces) |
| KvikIO | `kvikio-cu13==26.10.0` (or `-cu12` when the driver's CUDA major is 12), `cupy-cuda13x==14.2.0`, run with the host's libcufile 1.17.0 preloaded |
| nvidia-fs | v2.31.5 (commit `6a65099`), built with `NVFS_MAX_PEER_DEVS=128 NVFS_MAX_PCI_DEPTH=16` as the FSx for Lustre guide asks |

## Run

This investigation runs from the campaign's plan. To run it again by hand once the instance and /fsx are up:

```bash
cd ../2026-11-10-p5e-single-node-campaign
./3.run.sh 2026-11-10-gds-kvikio-fsx-lustre-efa/tasks/10-gds-stack.json
./3.run.sh 2026-11-10-gds-kvikio-fsx-lustre-efa/tasks/20-gdsio-fsx.json
./3.run.sh 2026-11-10-gds-kvikio-fsx-lustre-efa/tasks/30-kvikio-fsx.json
```

## Results

Measured on 2026-11-10 (p5e.48xlarge, sa-east-1). Raw records: [`results/p5e-2026-11-10/`](results/p5e-2026-11-10). Each cell was run once. The same test files were read many times, so part of the throughput can come from the file servers' cache; the provisioned throughput of this 4.8 TiB file system is about 4.8 GB/s, and single-GPU cells above that figure should be read with that in mind.

### The direct path works on FSx for Lustre over EFA

With cuFile's compat fallback disabled (`allow_compat_mode=false`), every gdsio read from /fsx succeeded, nvidia-fs counted the reads, and the EFA devices' `rdma_read_bytes` rose by the amount read. The Lustre client had two `@efa` peers after mounting. The same strict reads from the local instance store failed on every cell, as on p4d.24xlarge.

gdsio, one GPU, 4 MiB reads (`gdsio.jsonl`, label `fsx-1gpu`):

| Mode | Threads | GiB/s | CPU cores busy | nvidia-fs reads |
|---|---|---|---|---|
| GPU direct, compat disabled | 16 | 11.1 | 5.9 | 55,064 |
| GPU direct, compat disabled | 32 | 15.5 | 13.2 | 76,932 |
| cuFile forced to compat (`CUFILE_FORCE_COMPAT_MODE=true`) | 16 | 7.1 | 7.5 | 0 |
| cuFile forced to compat | 32 | 7.1 | 17.0 | 0 |
| gdsio CPU staging (`-x 2`) | 16 | 11.7 | 15.8 | 0 |
| gdsio CPU staging | 32 | 12.4 | 29.6 | 0 |

At the same thread count, the direct path read about as fast as CPU staging and twice as fast as cuFile's compat path, with about a third of the CPU of CPU staging. With 16 MiB reads the direct path stayed near 6.3 GiB/s at 16 and 32 threads. Eight GPUs reading at once reached 9.3 GiB/s in total with the direct path and 6.3 to 6.7 GiB/s with every other mode, which is near what this file system can serve.

### cuFile 1.20, which the KvikIO wheel installs, refuses the direct path on this file system

KvikIO 26.10.0 from PyPI brings its own libcufile (`nvidia-cufile 1.20.0.107`). With it, every strict read failed with `GPUDirect Storage not supported on current file`; cuFile logged `No RDMA-capable transport detected; activating compatibility mode for: <ip>@tcp:/<mount>` before the error. The FSx for Lustre mount names the management server with an `@tcp` address even when data moves over EFA, and cuFile 1.20 appears to take that as the transport. Replacing only the library with `LD_PRELOAD` (`50-cufile-version.json`, `results/p5e-2026-11-10/cufile-version/matrix.txt`):

| libcufile | gdsio, strict | KvikIO, strict |
|---|---|---|
| 1.13.1.3 (CUDA 12.8 on the AMI) | 10.5 GiB/s, nvidia-fs reads rose | reads rose (the harness then failed decoding `gds_stats` output, fixed since) |
| 1.14.1.1, 1.15.1.6 | 10.6 GiB/s, reads rose | reads rose |
| 1.17.0.44 (CUDA 13.2 on the AMI) | 15.9 GiB/s, reads rose | 16.8 GB/s, reads rose |
| 1.20.0.107 (the KvikIO wheel) | refused, no reads | refused, no reads |

With the AMI's cuFile 1.17 preloaded, KvikIO with `KVIKIO_COMPAT_MODE=off` read one 16 GiB file into one GPU at 18.0 GB/s with 16 threads and 9.9 CPU seconds, against 1.9 GB/s and 75.6 CPU seconds for `KVIKIO_COMPAT_MODE=on` at the same thread count (`kvikio.jsonl`). Eight GPUs at once were limited by the file system at 5.4 to 6.0 GB/s in both modes; the direct path used 80 to 86 CPU seconds and the compat path 120 to 254.

### Notes for reproducing

- The AMI (Deep Learning Base OSS Nvidia Driver GPU AMI, Ubuntu 24.04, 20261106) ships the Lustre client and the GDS tools but no nvidia-fs module for its 7.0 kernel; `10-gds-stack.json` builds nvidia-fs v2.31.5 from source. The `nvidia-fs-dkms` apt package would pull another kernel and driver.
- Use the cuFile on the host, not the one in the KvikIO wheel, until the transport check accepts this mount: `LD_PRELOAD=/usr/local/cuda-13.2/targets/x86_64-linux/lib/libcufile.so.1.17.0`.
- The EFA-enabled file system needs a security group rule allowing outbound traffic to itself, as an explicit rule.

## Contributing upstream

[awslabs/awsome-distributed-ai](https://github.com/awslabs/awsome-distributed-ai) has no GDS, nvidia-fs or KvikIO content yet. The closest material is the HyperPod lifecycle script that sets up the Lustre client for EFA (`1.architectures/5.sagemaker-hyperpod/LifecycleScripts/base-config/mount_fsx.sh`), which is owned by another team and stays where it is. The natural home is a new storage micro-benchmark, `micro-benchmarks/gpudirect-storage/`, shaped like `micro-benchmarks/expert-parallelism/ep-backend-comparison/` (a Python harness, run scripts, `results/*.json`, a results write-up, and README sections for requirements, the execution matrix and scope limits). For that move:

- rename the task steps to numbered scripts (`0.setup-gds.sh`, `1.make-test-files.sh`, `2.gdsio-sweep.sh`, `3.kvikio-read.sh`) and keep `scripts/*.py` as they are;
- add Slurm and Kubernetes launchers next to the plain-EC2 one, reusing the repository's FSx for Lustre modules;
- keep every version pinned as above and add the MIT-0 headers the repository uses.
