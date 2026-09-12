# FSx for Lustre client on Ubuntu: a reference implementation

The Amazon FSx for Lustre client is a kernel module, and the packaged modules are published per
exact kernel release. The documented install therefore names the running kernel in the package it
asks for:

```bash
apt install lustre-client-modules-$(uname -r)
```

That command fails whenever the repository carries no module for the release the host booted, and
which releases those are changes over time. This directory builds the client from the published
source instead, so the kernel release stops being part of what has to be available, and offers the
two shapes that matters for: a module baked into an image, and a module that follows kernel updates
on a long-lived host.

Everything here is a reference implementation, not an AWS-supported artefact. It uses only public
packages from the FSx for Lustre client repository.

## What is here

| Path | What it is |
| --- | --- |
| [`lustre_installer.sh`](lustre_installer.sh) | The whole procedure in one script. Runs standalone on any Ubuntu host and needs no other file from this directory |
| [`ansible/roles/aws_lustre/`](ansible/roles/aws_lustre) | A role that stages the script, calls it, and then asserts on the host that the module matches the running kernel and that a mount would work |
| [`ansible/playbook-lustre.yml`](ansible/playbook-lustre.yml) | Applies that role |
| [`ansible/playbook-lustre-kernel.yml`](ansible/playbook-lustre-kernel.yml) | Pins a kernel line and makes it the default boot entry, for an image build that wants a kernel other than the parent image's |
| [`packer/lustre-ami.pkr.hcl`](packer/lustre-ami.pkr.hcl) | Bakes the client into an AMI, two stages with a reboot between them |

The script is the only implementation. The role calls it rather than repeating it, so a host outside
any automation runs exactly what an image build runs.

## The three modes

```bash
sudo ./lustre_installer.sh -y                # build, the default
sudo ./lustre_installer.sh -y --mode dkms
sudo ./lustre_installer.sh -y --mode binary
```

| Mode | What it does | Right for |
| --- | --- | --- |
| `build` | Compiles the module for one kernel release and installs it as a package | An image. The module belongs to the artefact, a failed build fails the build, and nothing is compiled later on the running fleet |
| `dkms` | Registers the source with DKMS, so the module is rebuilt whenever a matching kernel is installed | A host that updates kernels in place, at the price of compiling on that host |
| `binary` | Installs the published module for the running kernel | A release the repository already covers. It reports and stops when there is none |

In `dkms` mode the kernel release disappears from everything an operator writes, which is what makes
it behave like the EFA installer: one entry point, and kernel updates are followed without anyone
naming a release.

## Installing on a running host

```bash
curl -fsSLO https://raw.githubusercontent.com/littlemex/distributed-ai/main/2026-09-10-fsx-lustre-client-kernel-abi/ansible/roles/aws_lustre/files/lustre_installer.sh
chmod +x lustre_installer.sh
sudo ./lustre_installer.sh -y --mode dkms --install-check-unit
```

The first run compiles the module and takes several minutes on a general purpose instance. Running
it again is safe and reports what it skipped.

Then mount a file system:

```bash
sudo mkdir -p /mnt/fsx
sudo mount -t lustre -o noatime,flock <file-system-dns-name>@tcp:/<mount-name> /mnt/fsx
```

`lustre-client-utils` is installed as part of the run and is not optional. Without
`/sbin/mount.lustre` the kernel receives the raw option list and refuses the mount, which reads like
a module problem and is not one.

## Which kernels DKMS may build for

DKMS builds from the kernel package's post-install hook. A build that fails there can leave the
kernel package unconfigured, which blocks later package operations until `dpkg --configure` runs. So
the client is not offered every kernel: the installer reads the repository index, keeps the kernel
series it publishes modules for in `/etc/lustre-installer/supported-kernels`, and copies that pattern
into the DKMS configuration.

```bash
sudo ./lustre_installer.sh --refresh-policy    # re-read the repository and update the registration
sudo ./lustre_installer.sh --refresh-policy --kernel-filter '^6\.8\.'   # be stricter than that
```

`--refresh-policy` rebuilds nothing and re-registers nothing, so it is safe from cron or a
configuration run. It is also the only thing that changes the policy: editing
`/etc/lustre-installer/supported-kernels` by hand does nothing until a refresh copies it into the
registration. The indirection that would have made a hand edit take effect immediately was removed
on purpose, because it made every later kernel installation depend on reading a mutable path from
inside a root-run package hook.

A kernel outside the policy is skipped rather than attempted, so package management stays healthy and
the host boots without a client instead. That absence is otherwise invisible until a mount fails,
which is what the boot-time check is for:

```bash
sudo ./lustre_installer.sh --install-check-unit   # adds lustre-client-check.service
systemctl status lustre-client-check              # after a reboot
sudo ./lustre_installer.sh --check                # the same question, now
```

The unit reports and does not block boot. Wiring its result into scheduling, for example a taint
applied by a node agent, is left to whatever manages the fleet.

## Baking it into an AMI

```bash
cd packer
packer init lustre-ami.pkr.hcl
packer build -var parent_ami_ssm=/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id lustre-ami.pkr.hcl
```

The build runs Ansible twice with a reboot between them. That reboot only matters when
`lustre_kernel_meta` names a kernel line to pin. A module can be built for a kernel that is not
running, given its headers, and `--kernel` does exactly that; the reboot is here because the
installer targets the running kernel by default, and because it lets the image prove that the module
it carries loads on the kernel the image actually boots. With the variable left empty the first stage
and the reboot do nothing, and the image keeps the kernel its parent booted.

Pinning is a choice about the kernel's own support lifecycle, not a workaround for module
availability. Building from source already removed the dependence on which exact releases are
published.

## Options

```
-y, --yes                 do not ask for confirmation
-m, --mode MODE           build (default), dkms, or binary
-k, --kernel REL          kernel release to install for; defaults to the running kernel
-s, --suite NAME          repository suite; defaults to this system's codename
    --key-fingerprint FPR expected fingerprint of the repository signing key
-n, --no-verify           skip the post-install verification
-u, --uninstall           remove every Lustre client on this host
-c, --check               exit 0 when the running kernel has a loadable, mountable module
    --install-check-unit  also install the systemd unit that runs --check at boot
    --kernel-filter REGEX kernels DKMS may build for; derived from the repository by default
    --refresh-policy      refresh that derived list and exit
-q, --quiet               less output
-v, --version             print the installer version and exit
-h, --help                print the help and exit
```

`--help` prints the same list with the reasoning behind each mode.

## A release the repository has no suite for

The repository carries a suite per Ubuntu LTS, and a new one appears some months after the release
it is for. Until it does, point at a suite that exists and build locally, which works because the
module is compiled against this host's kernel either way:

```bash
sudo ./lustre_installer.sh -y --mode dkms --suite noble
```

The userspace tools then also come from that suite. Check that they run before relying on them.

## Requirements and boundaries

- Ubuntu. On Amazon Linux 2023 the kernel package provides the module, so `dnf install -y lustre-client` is all that is needed and none of this applies.
- Root, for every action including `--check`, which answers its question by loading the module.
- Network access to the FSx for Lustre client repository. The signing key is pinned by fingerprint and a substituted key is refused rather than trusted.
- `dkms` and `build` modes compile on the host, so they need the build dependencies the script installs, including three the source package does not declare.
- Verified on x86-64. arm64 and 64 KB page kernels are handled by the same code paths but have not been exercised.
- Removing the client is host-wide: `--uninstall` removes every Lustre module, DKMS registration, source tree and module package it finds, not only the ones this script created.

## Uninstalling

```bash
sudo ./lustre_installer.sh --uninstall -y
```

It unmounts, unloads, deregisters, removes the packages, removes the boot-time check and its own
copy, and reports anything it could not finish rather than exiting quietly. The repository
registration and its signing key are left in place, because they are apt configuration an
administrator may have adopted.
