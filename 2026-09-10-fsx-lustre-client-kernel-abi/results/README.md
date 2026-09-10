# Captured output

Two runs on Ubuntu 24.04.4 LTS, kernel `6.8.0-1063-aws`, against a `PERSISTENT_2` file
system running Lustre 2.12 with four object storage targets: the ABI and mount sequence on
`m5.large`, and the load, recovery and reboot sequence on `m5.2xlarge`. Account, region,
file system, instance and address identifiers are redacted.

| File | Step | What it shows |
| --- | --- | --- |
| `repo-suites-amd64.txt` / `repo-suites-arm64.txt` | repository inventory | Highest module build per kernel series per suite: the 6.8 series reaches `1063` in the 22.04 suite and stops at `1057` in the 24.04 suite, on both architectures |
| `kernel-abi-6.8.0-1063-amd64.txt` / `.json` | static check | 26,848 exported symbols identical between the two kernel builds; 2,145 module imports checked against each, 0 CRC mismatches; verdict `LOADABLE` |
| `run-02-add-release-suite-repo.txt` | repository state | The suite matching the OS release offers 6.8 builds only up to `6.8.0-1057-aws`, plus 6.14 and 6.17 series builds |
| `run-03-control-release-suite-only.txt` | control | `E: Unable to locate package lustre-client-modules-6.8.0-1063-aws`; `lustre-client-modules-aws` resolves to `6.17.0-1019`, a kernel the host is not running; `modinfo lustre` reports the module is absent |
| `run-04-install-cross-suite-module.txt` | positive case | The module for the running kernel resolves from the second suite at `2.15.6-1fsx34`; `vermagic` equals the running kernel release; `lustre`, `lnet`, `ptlrpc`, `obdclass`, `libcfs` and `ksocklnd` load |
| `run-05-mount-and-io.txt` | file system traffic | Mount succeeds; 512 MiB written and read back with identical md5; 200 files created and removed; 751 MB/s write and 816 MB/s read; unmount and mount again with the payload intact |
| `run-07-control-mismatched-module.txt` | control | A build for `6.8.0-1057-aws` is rejected by the same kernel with `Invalid module format` and `libcfs: disagrees about version of symbol module_layout`, while the matching build still loads |
| `run-08-load-and-recovery.txt` | load, locking, recovery, health | 4 `fio` jobs with `crc32c` verification and `verify_fatal=1` finish at `err=0`; 60 s of mixed random load at 16.7k read IOPS; the `flock` counter reaches exactly 200; the client goes to `CONNECTING` while traffic is blocked and back to `FULL` afterwards with every target active, the write held during the outage exits 0 and both checksums verify; taint is out-of-tree and unsigned module only, with no BUG, oops, call trace, lockup or runtime warning |
| `run-08-load-and-recovery-long-pass.txt` | longer load pass | The same sequence with 8 jobs, 4 GiB verified writes at 1178 MiB/s and 180 s of mixed load moving 254 GiB at `err=0` |
| `run-08-recovery-step-detail.txt` | recovery detail | The client's own log lines for the outage and the recovery, read back from the node because Systems Manager truncates long command output |
| `run-09-boot-persistence.txt` | reboot | After a reboot the node is on the pinned kernel, the module is loaded, the systemd mount unit is `active` and the canary file's checksum matches |
| `run-12-installer-script.txt` | one-command install and kernel update | `lustre_installer.sh -y` installs the client with DKMS in 515 s on a clean host and reports `already` at every step on a second run 8 s later; installing another kernel release rebuilds the module during `apt install`; the file system mounts on the new kernel with no installer run in between; `--mode binary` refuses with the reason on a release that has no published module |
| `run-13-dkms-hook-behaviour.txt` | what a failed DKMS build does to apt | With the kernel filter, installing `linux-image-7.0.0-1012-aws` returns 0 and DKMS skips it, leaving no module for that kernel. Without the filter the same install returns 100, `run-parts: /etc/kernel/postinst.d/dkms exited with return code 11`, and the kernel package is left `install ok half-configured`, which `dpkg --audit` reports |
| `run-06-collect-evidence.txt` | final state | Package origins, module metadata, mount state, `lfs check servers` reporting every target active, and the client's kernel log lines |

The throughput figures are incidental. They come from `dd` and `fio` on one client and are
reported only to show that the data path carried real traffic. The `LustreError` lines in the
recovery logs are the deliberate outage; nothing else in the runs produced one.
