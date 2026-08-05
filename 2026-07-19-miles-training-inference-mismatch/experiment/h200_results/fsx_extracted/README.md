# FSx Extracted Data (2026-08-05/06)

TensorBoard event files from two FSx filesystems, extracted via CPU pods while
GPU Capacity Blocks were expired.

## Source filesystems

| FSx | Cluster | GPU | Period | Status at extraction |
|---|---|---|---|---|
| `fs-0b5c35b493051ba74` (us-east-2) | `distai-p5-ue2` | H100 + H200 | Aug 2-4 | AVAILABLE |
| `fs-060b42fa6065cbed8` (us-east-2) | `distai-eks-smoke` | H200 only | Jul 17-21 | AVAILABLE |

## Files

| File | Size | Content |
|---|---|---|
| `aug_per_step_10runs.json` | 82K | Full per-step values (mis_kl, grad_norm, reward, repetition, update_weights) for 10 key runs. **Use this for figures.** |
| `aug_68runs_summary.json` | 84K | All 68 Aug runs: first/last/max/n per metric, wall_first/wall_last |
| `jul_32runs_summary.json` | 13K | All 32 Jul runs: same format |
| `jul_20runs_full.json` | 265K | 20 key Jul runs: full per-step values for all metrics |
| `jul_tags.json` | 53K | TB scalar tag lists per Jul run (for framework discrimination) |
| `aug_tags.json` | 159K | TB scalar tag lists per Aug run (for framework discrimination) |

## S3 Backup

```
s3://<account-bucket>/fsx-forensic-backup-20260806/
```

Region: us-east-1 (relay bucket). Same files as this directory.

## Extraction method

1. Launch a CPU-only pod mounting the FSx PVC (no GPU needed)
2. `pip install tensorboard` in the pod
3. Python script using `EventAccumulator` to read all scalars
4. Write JSON to FSx, then `kubectl exec cat` to retrieve locally

The FSx filesystems have `persistentVolumeReclaimPolicy: Retain` and remain
accessible as long as the EKS cluster exists, even without GPU nodes.
