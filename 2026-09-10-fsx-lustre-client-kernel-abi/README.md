# FSx for Lustre client modules across Ubuntu suites: kernel ABI verification

The FSx for Lustre Ubuntu repository publishes one binary client module per exact kernel
release, and it publishes those packages per Ubuntu suite. The published sets differ: a
kernel release can be covered in one suite and absent from another, even when both suites
ship that same kernel release. Ubuntu 24.04 carries the 6.8 kernel as its GA kernel, and
Ubuntu 22.04 carries the same 6.8 kernel as a hardware-enablement kernel, so the two
suites overlap over the whole 6.8 series.

This directory answers one question with evidence: **when the repository has no module for
the kernel release a host is running, but another suite has a module for that exact
release, does that module work?**

It answers it twice, once statically from package contents and once on a running client
with real file system traffic. It includes the two controls that make the positive result
meaningful, and it goes past a smoke test: concurrent verified I/O, advisory locking under
contention, loss and recovery of the connection to the servers, mounting again after a
reboot, and a scan of the kernel for faults.

## What the answer is

For kernel release `6.8.0-1063-aws` on Ubuntu 24.04, using the module built in the 22.04
suite:

| Check | Method | Result |
| --- | --- | --- |
| Kernel-to-kernel ABI | Compare `Module.symvers` of both `linux-headers` packages | 26,848 exported symbols on both sides, 0 CRC differences, no symbol present on only one side |
| Module-to-kernel ABI | Parse `vermagic` and the `__versions` records of all 17 objects, compare against the running kernel's symbol table | `vermagic` matches the kernel release; 2,145 kernel symbol imports checked, 0 CRC mismatches |
| Module loads | `modprobe lustre` on the running kernel | Loaded, `Lustre: Build Version: 2.15.6`, LNet accepting on port 988 |
| File system works | Mount, 512 MiB write and read back, 200 metadata operations, unmount and mount again | Checksums identical, 751 MB/s sequential write, 816 MB/s sequential read, data intact across the remount |
| Control: release-matching suite alone | Follow the documented install on the same host with only the 24.04 suite registered | `E: Unable to locate package lustre-client-modules-6.8.0-1063-aws`; the module meta package resolves to a build for a different kernel release |
| Control: mismatched build | `insmod` a module built for `6.8.0-1057-aws` into the same running kernel | Rejected: `Invalid module format`, `libcfs: disagrees about version of symbol module_layout` |
| Concurrent load with data verification | `fio`, 8 jobs, direct I/O, 4 GiB written and read back with `crc32c` verification and `verify_fatal=1` | `err=0`, no verification failure, 1178 MiB/s write and 1117 MiB/s read |
| Sustained mixed load | `fio` random 70/30 read and write, 8 jobs, 180 s, 254 GiB moved | `err=0`, 16.2k read IOPS and 7.0k write IOPS throughout |
| Advisory locking | Four processes take `flock` on one file and increment a counter 50 times each | Counter reaches exactly 200; `llite` statistics record 800 `flock` operations |
| Connection loss and recovery | Drop client traffic to port 988, keep a write in flight, restore after 90 s | Imports go to `CONNECTING` and report `Connection to ... was lost`, then `Connection restored`, all imports return to `FULL`, `lfs check servers` reports every target active, the in-flight write completes with exit 0, and checksums before and after the outage match |
| Mount after a reboot | fstab entry with `_netdev,x-systemd.automount`, reboot, verify | Node comes back on the pinned kernel, the module is loaded, the systemd mount unit is `active` and the canary file's checksum still matches |
| Kernel health | Decode `/proc/sys/kernel/tainted`, scan for faults and runtime warnings | Taint bits 12 and 13 only, which are out-of-tree and unsigned module, both expected for any third-party module and attributed by the kernel to `libcfs`; no BUG, oops, call trace, lockup or hung task; no runtime warning; the only `LustreError` lines are the MGS disconnects caused by the deliberate outage |

The second control matters. Without it, a successful load proves nothing about whether the
kernel validates anything. The kernel does validate, it rejects a build from a neighbouring
release of the same series, and it accepts the cross-suite build for the matching release.

Two facts fell out of the verification and are worth stating separately.

The current Ubuntu 24.04 AMI boots a rolling `linux-aws` kernel from a series the
repository does not cover at all, so a freshly launched instance has no module available
under any suite until a kernel is chosen deliberately. `iac/` and
`setup/tasks/01-install-target-kernel.json` therefore pin the kernel release under test
rather than assuming the image's kernel.

Userspace and kernel space have different constraints. `lustre-client-utils` is published
at the same version in both suites, so only the module package needs to come from the other
suite.

## Reproducing it

### Static check, no infrastructure

```bash
./scripts/list-repo-kernels.sh
./scripts/compare-kernel-abi.py \
    --module-url https://fsx-lustre-client-repo.s3.amazonaws.com/ubuntu/pool/jammy/l/lu/lustre-client-modules-6.8.0-1063-aws_2.15.6-1fsx34_amd64.deb \
    --headers-url http://archive.ubuntu.com/ubuntu/pool/main/l/linux-aws/linux-headers-6.8.0-1063-aws_6.8.0-1063.66_amd64.deb \
    --headers-url http://archive.ubuntu.com/ubuntu/pool/main/l/linux-aws-6.8/linux-headers-6.8.0-1063-aws_6.8.0-1063.66~22.04.1_amd64.deb \
    --json results/kernel-abi-6.8.0-1063-amd64.json
```

`list-repo-kernels.sh` prints, per suite and architecture, the highest module build for
each kernel series. `compare-kernel-abi.py` exits non-zero when a module would not load,
so it can gate a pipeline.

### On a client instance

The client runs in a private subnet, is reached only through AWS Systems Manager, and joins
the security groups of the file system so the self-referencing Lustre rules apply. Every
command on the node comes from a JSON task definition.

```bash
cd iac/terraform
cp terraform.tfvars.example terraform.tfvars   # fill in region, subnet, file system security group
terraform init
terraform apply

export AWS_REGION=<region>
export INSTANCE_ID=$(terraform output -raw instance_id)
cd ../../setup

./runner.sh wait
./runner.sh deploy
./runner.sh run tasks/01-install-target-kernel.json     # pins and boots the kernel under test
./runner.sh wait                                       # the step above reboots the node
./runner.sh run tasks/01-install-target-kernel.json     # idempotent, confirms the running kernel
./runner.sh run tasks/02-add-release-suite-repo.json
./runner.sh run tasks/03-control-release-suite-only.json
./runner.sh run tasks/04-install-cross-suite-module.json --env CROSS_SUITE=jammy
./runner.sh run tasks/05-mount-and-io.json \
    --env FSX_DNS_NAME=<file system DNS name> \
    --env FSX_MOUNT_NAME=<mount name> \
    --env IO_SIZE_MB=512
./runner.sh run tasks/07-control-mismatched-module.json --env OTHER_KERNEL=6.8.0-1057-aws
./runner.sh run tasks/06-collect-evidence.json

# behaviour under load, during a connection outage, and across a reboot
./runner.sh run tasks/08-load-and-recovery.json --timeout 2400 \
    --env FSX_DNS_NAME=<file system DNS name> \
    --env FSX_MOUNT_NAME=<mount name> \
    --env FIO_JOBS=8 --env FIO_SIZE=512M --env LOAD_SECONDS=180 \
    --env OUTAGE_SECONDS=120 --env RECOVERY_SECONDS=90
./runner.sh run tasks/09-boot-persistence.json --timeout 300 \
    --env FSX_DNS_NAME=<file system DNS name> \
    --env FSX_MOUNT_NAME=<mount name>   # this run ends when the node reboots
./runner.sh wait
./runner.sh run tasks/09-boot-persistence.json \
    --env FSX_DNS_NAME=<file system DNS name> \
    --env FSX_MOUNT_NAME=<mount name>   # verifies the mount that came back
./runner.sh logs 08                     # read a step log back from the node
```

Task 8 interrupts Lustre traffic with a local `iptables` rule on the client, so it affects
only that client and needs no change on the server side. Systems Manager truncates command
output, which is why `runner.sh logs` exists: `task_runner.sh` keeps one log file per step
on the node.

Destroy the client when finished:

```bash
cd ../iac/terraform && terraform destroy
```

Task state lives on the node under `/var/log/task-runner/<step>.log`, and each step declares
`skip_if` so a task can be re-run without repeating work. Terraform state for this stack is
local, because the stack is one throwaway instance.

## Layout

```
iac/terraform/   client instance, its instance profile and its egress security group
setup/           runner.sh (Systems Manager transport), task_runner.sh (JSON task engine), tasks/
scripts/         static repository and ABI checks that need no AWS account
results/         captured output of the runs described above
```

## Scope and limits

The verification covers `amd64` and the kernel release named above, on a single client. It
says nothing about combinations it did not run: another kernel series, `arm64`, the 64 KB
page size variants, several clients sharing files at once, EFA rather than TCP for LNet, a
run measured in days rather than minutes, or the behaviour of a kernel upgrade that moves
the host off the pinned release. `compare-kernel-abi.py` answers those cheaply, and the module packages for
`arm64` exist in the same suites.

Installing a module package from a suite other than the one that matches the OS release is
not part of the documented installation procedure. The evidence here says the artefact is
ABI-compatible and works; it does not make the combination a supported configuration.

Identifiers in `results/` are redacted.
