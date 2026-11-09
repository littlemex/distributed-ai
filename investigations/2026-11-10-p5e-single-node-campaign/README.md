# One p5e.48xlarge Capacity Block, five investigations

This directory holds the infrastructure and the task engine shared by five investigations that run on one p5e.48xlarge (8x H200, 32 EFA interfaces, 8x 3.84 TB instance store) bought as a 24-hour Capacity Block. Each investigation lives in its own sibling directory, with its own README, scripts and task files, and keeps its results there.

| Investigation | Question |
|---|---|
| [`2026-11-10-gds-kvikio-fsx-lustre-efa`](../2026-11-10-gds-kvikio-fsx-lustre-efa) | Does a KvikIO or cuFile read from FSx for Lustre over EFA land in GPU memory directly, and what does it cost in CPU compared with staging through host memory? |
| [`2026-11-10-torchtitan-checkpoint-fsx-lustre`](../2026-11-10-torchtitan-checkpoint-fsx-lustre) | How long does training stop for a Llama 3 8B checkpoint, and how long until it is really on storage, for each torchtitan checkpointer on FSx for Lustre and on local NVMe? |
| [`2026-11-10-torchtitan-rl-batch-invariant`](../2026-11-10-torchtitan-rl-batch-invariant) | Are TitanRL trainer and vLLM generator logprobs bitwise identical in batch-invariant mode, and how far apart are they without it? |
| [`2026-11-10-diffusion-lm-serving-sglang`](../2026-11-10-diffusion-lm-serving-sglang) | How does a diffusion LM (LLaDA2.1-mini) served by SGLang compare with its autoregressive sibling (Ling-mini-2.0) on latency, throughput and GSM8K? |
| [`2026-11-10-torchtitan-flexshard-muon`](../2026-11-10-torchtitan-flexshard-muon) | How long is one optimizer step for Llama 3 8B-shaped sharded weights with AdamW, with Muon on gathered matrices, and with FlexShard DistMuon? |

## Layout

```
2026-11-10-p5e-single-node-campaign/
├── env.example            values for env.sh (region, AZ, AMI, Capacity Block id, launch times)
├── 0.deploy-infra.sh      CDK deploy: VPC, security group, results bucket, FSx control function,
│                          launch template, scheduled launch and scheduled FSx cleanup
├── 1.upload-bundle.sh     upload the investigation directories the plan uses to S3
├── 2.status.sh            instance, FSx state, and the state of every task file on the host
├── 3.run.sh               run one task file on the instance through SSM Run Command
├── 4.pull-results.sh      download a run and copy each investigation's part into its results/
├── 5.destroy.sh           delete FSx, terminate the instance, destroy the stack (bucket is kept)
├── cdk/                   the stack (lib/campaign-stack.ts) and the FSx control Lambda
├── host/
│   ├── bootstrap.sh       user data: config from SSM, bundle from S3, results sync loop, the plan
│   ├── task_runner.sh     the JSON task engine (idempotent, per-task logs, GPU lock)
│   ├── plan.txt           the order of task files on the Capacity Block instance
│   └── plan-smoke.txt     the dry-run order on a small single-GPU instance
└── tasks/                 shared task files: host snapshot, local NVMe RAID0, FSx up and down
```

## Design

| Decision | Why | Alternatives considered |
|---|---|---|
| The instance launches itself through EventBridge Scheduler calling `RunInstances` at the block start, with several attempts | The block opens at a fixed time whether or not an operator is awake. A second success is impossible because the block holds one instance, so retries are safe | A person launching it by hand; a Lambda polling the reservation state |
| Every remote command is a JSON task file run by one engine (`host/task_runner.sh`) | Each task is idempotent (a succeeded task is skipped on rerun), every task has its own log, and the same file runs unattended from the plan or on demand through `3.run.sh` | Per-investigation shell scripts; SSH sessions |
| A GPU lock (`"gpu": true` in a task file takes `/var/lock/campaign-gpu.lock`) | Several investigations, and other operators, share one node. Two measurements on the same GPUs at the same time would both be wrong | Running everything strictly from one plan; separate instances |
| A private subnet behind a NAT gateway | An instance with more than one network card gets no public IPv4 address, and SSM, S3 and package installs still need a way out. The S3 gateway endpoint keeps result uploads off the NAT | A public subnet plus an Elastic IP attached after launch |
| One EFA interface on each of the 32 network cards (card 0 `efa`, the others `efa-only`) | FSx for Lustre's EFA client script and NCCL both use the EFA devices they find; `efa-only` interfaces take no IP addresses from the subnet | Only the interfaces FSx needs (8) |
| A security group allowing all traffic to and from itself, in both directions | EFA requires an outbound rule to the group itself, and FSx for Lustre over EFA uses the same group | Separate groups for the instance and the file system |
| The FSx for Lustre file system is created by the instance at boot and deleted as soon as the FSx tasks finish, with a scheduled delete after the block ends as a backstop | A 4.8 TiB EFA-enabled Persistent 2 file system bills by the hour; creating it at boot overlaps its creation with software installs | Creating it the day before; a separate CDK stack deployed by hand |
| Results sync to a retained, versioned S3 bucket every minute | The instance disappears at the end of the block; nothing on it must be the only copy | Copying results at the end only |

## Reproduce

Requirements: AWS CLI v2, Node.js 20 or later with npm, Python 3, and credentials that can create VPC, EC2, IAM, Lambda, EventBridge Scheduler, SSM, S3 and FSx resources. The AWS account needs a Capacity Block for the instance type in the chosen Availability Zone.

```bash
cp env.example env.sh
```

Fill in `env.sh`: the Capacity Block id, its Availability Zone, launch times a few minutes after the block starts, a cleanup time after it ends, and the pinned AMI id (the command to look it up is in the file). Then deploy and upload:

```bash
./0.deploy-infra.sh
./1.upload-bundle.sh
```

The instance starts at the first launch time and runs `host/plan.txt`. Follow it with:

```bash
./2.status.sh
```

Run a single task file again, or one that is not in the plan:

```bash
./3.run.sh 2026-11-10-gds-kvikio-fsx-lustre-efa/tasks/30-kvikio-fsx.json --force
```

After the block ends, download the results and delete everything except the bucket:

```bash
./4.pull-results.sh
./5.destroy.sh
```

## Dry run before the block

`host/bootstrap.sh` runs `host/plan-smoke.txt` on any instance type other than P5 or P6. Launching a small GPU instance (the only one offered in sa-east-1c was g4dn.xlarge) into the same subnet with the same instance profile and user data checks the bootstrap, the bundle, every installer and every pinned version, without the cost of the block.

## Sharing the instance with another operator

Another session can run its own task files on the same instance with `3.run.sh`, or with its own runner, as long as its GPU-heavy commands hold the same lock:

```bash
flock /var/lock/campaign-gpu.lock <command>
```

The plan then waits for that command to finish before its next GPU task file, and the other way round.

## Known limits

- The plan runs task files in one fixed order. A task file that fails does not stop the plan; its log and state are synced like any other, and it can be rerun with `3.run.sh`.
- If the Capacity Block's start is delayed beyond the last scheduled attempt, launch the instance by hand with the launch template.
