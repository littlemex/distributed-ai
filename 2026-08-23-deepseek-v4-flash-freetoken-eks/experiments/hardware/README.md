# Hardware experiment: Intel + more VRAM (g7e.8xlarge)

**Status: not run — blocked by EC2 capacity, not by configuration.**

## Why this instance

The L40S measurements identified exactly two binding constraints, and `g7e.8xlarge` moves both
while holding host RAM constant at 256 GiB:

| | g6e.8xlarge (measured) | g7e.8xlarge (target) |
|---|---|---|
| GPU | 1x L40S, **45 GiB** | 1x RTX PRO Server 6000, **96 GiB** |
| CPU | AMD EPYC Milan — **no AVX-512** | **Intel** — AVX-512 |
| host RAM | 256 GiB | 256 GiB |
| vCPU | 32 | 32 |
| on-demand, us-east-2 | $4.53/hr | $5.27/hr |

**VRAM** is what sets expert residency, measured at 19.9% (2 193 of 11 008 slots), leaving ~80% of
expert accesses to miss. Roughly 86 GiB free after dense weights could hold ~6 700 slots, i.e.
**~61% residency**, cutting the miss rate from 80% to ~39%.

**CPU vector tier** is what gates the term hybrid depends on. `ft bench bw` reported `isa=avx2`
because Milan has no AVX-512, yet FreeToken ships a dedicated `dot_dsfp4_avx512` and dispatches to
it only on capable hardware:

```c
if (t >= ISA_AVX512) return dot_dsfp4_avx512;
if (t >= ISA_AVX2)   return dot_dsfp4_avx2;
```

The AVX-512 variant processes 16 weights per block against AVX2's 8, against a measured CPU-MoE
bandwidth of 61.9 GB/s that hybrid's entire advantage rests on.

Note this moves TWO variables, so a raw tok/s delta could not be attributed to either alone. Two
log lines separate them: the bench's `isa=` line for the CPU half, and
`--moe-cache-auto resolved moe_cache_size=` for the residency half.

## What actually happened

Both AZs where `g7e.8xlarge` is offered refused, each pointing at the other:

```
InsufficientInstanceCapacity: We currently do not have sufficient g7e.8xlarge capacity in the
Availability Zone you requested (us-east-2a). ... You can currently get g7e.8xlarge capacity by
not specifying an Availability Zone in your request or choosing us-east-2b.
```
```
... in the Availability Zone you requested (us-east-2b). ... or choosing us-east-2a.
```

`g7e.8xlarge` is not offered in `us-east-2c` at all. Karpenter then caches the insufficient-capacity
error and reports `skipping, nodepool requirements filtered out all instance types`, which reads
like a misconfiguration but is not one — the underlying cause is only visible in the NodeClaim's
launch error.

Quota was not the limit: `Running On-Demand G and VT instances` is 64 vCPU and this needs 32.

## What this cost us in a way worth recording

Getting here exercised the single-AZ constraint that both reviews flagged as a risk, and confirmed
it is a real operational hazard rather than a theoretical one. The S3 Files file system has one
mount target per AZ, the NFS endpoint resolves per-AZ, and the PV's `nodeAffinity` therefore pins
every consumer pod. So the AZ chosen for storage silently constrains which instance types are
reachable — and `setup-s3files.sh` had picked `us-east-2c` on the entirely reasonable grounds that
it offers `g6e.8xlarge`.

That is what `setup-s3files.sh --add-zone <az>` now exists for: it adds a mount target in another
AZ against the same file system and data, and prints the second PV/PVC to bind. Two extra mount
targets (`us-east-2a`, `us-east-2b`) were created this way and both PVCs bound cleanly, so the
storage layer was never the blocker — only EC2 capacity was.

## Retrying

Capacity fluctuates, so this is worth re-attempting rather than abandoning:

```bash
./storage/setup-s3files.sh --add-zone us-east-2a     # or us-east-2b; both already exist
helm upgrade --install freetoken-model-cache-us-east-2a storage/model-cache \
  --set name=freetoken-model-cache-us-east-2a --set volumeHandle="s3files:<fs>::<ap>" \
  --set zone=us-east-2a --set namespace=freetoken

# edit the zone pin in nodepool-gpu-rtxpro-1x.yaml and the claimName in dsv4-g7e-intel.values.yaml
kubectl apply -f experiments/hardware/nodepool-gpu-rtxpro-1x.yaml
helm template x serving/charts/freetoken-serving \
  -f serving/values/deepseek-v4-flash.values.yaml \
  -f experiments/hardware/dsv4-g7e-intel.values.yaml \
  --set image=<ecr-image> -n freetoken | kubectl -n freetoken apply -f -
```

Watch for the launch error rather than the scheduler message:

```bash
kubectl -n karpenter logs deploy/karpenter --tail=400 | grep "failed launching nodeclaim"
```

A Capacity Block or Capacity Reservation would remove the uncertainty for a planned run.

## Alternatives considered

- `g4dn.16xlarge` — Intel with AVX-512 and 256 GiB RAM, but a single 16 GiB T4. Dense weights alone
  are ~10 GiB, so there is almost no room for an expert cache, and Turing predates the FP4 paths
  this checkpoint needs.
- `p4d.24xlarge` — Intel, 1.1 TB RAM, 8x A100 40 GiB. Technically capable but ~$32/hr for a
  single-GPU question, and seven idle GPUs.

Neither isolates the two variables as cleanly as `g7e.8xlarge`, which is why this stays the target.
