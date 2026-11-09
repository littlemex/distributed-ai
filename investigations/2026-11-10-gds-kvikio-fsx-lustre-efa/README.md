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
│   └── kvikio_read.py            KvikIO reads, one process per GPU, JSON line per run
├── tasks/
│   ├── 10-gds-stack.json         nvidia-fs, cuFile configs, gdscheck, KvikIO venv (pinned)
│   ├── 20-gdsio-fsx.json         test files on /fsx and the gdsio matrix
│   ├── 30-kvikio-fsx.json        KvikIO strict and compat
│   └── 40-local-nvme-control.json  the same reads from /local
└── results/                      filled by ../2026-11-10-p5e-single-node-campaign/4.pull-results.sh
```

## Environment

| Item | Value |
|---|---|
| Instance | p5e.48xlarge, sa-east-1c, Capacity Block |
| AMI | Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04) 20261106, `ami-0169a766f567bc432` (Lustre client, EFA and nvidia-fs preinstalled) |
| File system | FSx for Lustre 2.15, Persistent 2, SSD, 4.8 TiB, 1000 MB/s/TiB, EFA enabled, automatic metadata configuration |
| Lustre client | AWS `configure-efa-fsx-lustre-client` script with `--optimized-for-gds` (its default on p5e is 8 EFA interfaces) |
| KvikIO | `kvikio-cu13==26.10.0` (or `-cu12` when the driver's CUDA major is 12), `cupy-cuda13x==14.2.0` |

## Run

This investigation runs from the campaign's plan. To run it again by hand once the instance and /fsx are up:

```bash
cd ../2026-11-10-p5e-single-node-campaign
./3.run.sh 2026-11-10-gds-kvikio-fsx-lustre-efa/tasks/10-gds-stack.json
./3.run.sh 2026-11-10-gds-kvikio-fsx-lustre-efa/tasks/20-gdsio-fsx.json
./3.run.sh 2026-11-10-gds-kvikio-fsx-lustre-efa/tasks/30-kvikio-fsx.json
```

## Results

Pending: the Capacity Block runs 2026-11-10 20:30 to 2026-11-11 20:30 JST.

## Contributing upstream

[awslabs/awsome-distributed-ai](https://github.com/awslabs/awsome-distributed-ai) has no GDS, nvidia-fs or KvikIO content yet. The closest material is the HyperPod lifecycle script that sets up the Lustre client for EFA (`1.architectures/5.sagemaker-hyperpod/LifecycleScripts/base-config/mount_fsx.sh`), which is owned by another team and stays where it is. The natural home is a new storage micro-benchmark, `micro-benchmarks/gpudirect-storage/`, shaped like `micro-benchmarks/expert-parallelism/ep-backend-comparison/` (a Python harness, run scripts, `results/*.json`, a results write-up, and README sections for requirements, the execution matrix and scope limits). For that move:

- rename the task steps to numbered scripts (`0.setup-gds.sh`, `1.make-test-files.sh`, `2.gdsio-sweep.sh`, `3.kvikio-read.sh`) and keep `scripts/*.py` as they are;
- add Slurm and Kubernetes launchers next to the plain-EC2 one, reusing the repository's FSx for Lustre modules;
- keep every version pinned as above and add the MIT-0 headers the repository uses.
