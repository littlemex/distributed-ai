"""Host-side counters that tell which path a read took, sampled before and after each run.

- nvidia-fs: /proc/driver/nvidia-fs/stats "Reads" line. Counts reads that went through nvidia-fs,
  including failed ones (check io_state_err), and does not count cuFile's compat (bounce) reads.
- EFA: per-device hardware counters under /sys/class/infiniband/*/ports/1/hw_counters. FSx for Lustre
  servers move bulk data with RDMA, so a read that lands in GPU memory over EFA shows up here while
  the host's CPU-side copy counters stay flat.
- CPU: system-wide busy jiffies from /proc/stat, and the children's rusage of the calling process.
"""
import glob
import os
import re
import resource

EFA_KEYS = ("rdma_read_bytes", "rdma_read_resp_bytes", "rdma_write_bytes", "rdma_write_recv_bytes",
            "rx_bytes", "tx_bytes", "rdma_read_wr_err", "rdma_write_wr_err")


def nvfs():
    try:
        txt = open("/proc/driver/nvidia-fs/stats").read()
    except OSError:
        return {}
    m = re.search(r"^Reads\s*:\s*(.*)$", txt, re.M)
    if not m:
        return {}
    return {f"nvfs_read_{k}": float(v) for k, v in re.findall(r"(\w+)=([\d.]+)", m.group(1))}


def efa():
    out = {k: 0 for k in EFA_KEYS}
    for dev in glob.glob("/sys/class/infiniband/*/ports/1/hw_counters"):
        for k in EFA_KEYS:
            p = os.path.join(dev, k)
            if os.path.exists(p):
                out[k] += int(open(p).read().strip() or 0)
    return {f"efa_{k}": v for k, v in out.items()}


def cpu():
    f = open("/proc/stat").readline().split()[1:]
    vals = list(map(int, f))
    idle = vals[3] + vals[4]
    ru = resource.getrusage(resource.RUSAGE_CHILDREN)
    return {"cpu_busy_jiffies": sum(vals) - idle, "children_cpu_sec": ru.ru_utime + ru.ru_stime}


def sample():
    return {**nvfs(), **efa(), **cpu()}


def delta(before, after):
    d = {k: after[k] - before[k] for k in after if k in before}
    hz = os.sysconf("SC_CLK_TCK")
    if "cpu_busy_jiffies" in d:
        d["cpu_busy_sec"] = d.pop("cpu_busy_jiffies") / hz
    return d
