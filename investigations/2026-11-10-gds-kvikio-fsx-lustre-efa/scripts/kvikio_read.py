"""Read files into GPU memory with KvikIO and report throughput, CPU time and which path was taken.

One process per GPU (--gpus N spawns N workers, GPU i reads file f<i> from --dir). Each worker:
  - opens the file with kvikio.CuFile and records whether KvikIO chose its own compat (POSIX) mode,
  - warms up CUDA, cuFile and the KvikIO thread pool with one 64 MiB read, then reads the whole file
    into one CuPy buffer once and times it. One timed read per process keeps the page cache out of the
    measurement (the parent drops caches first); repeat runs for more samples.
  - runs gds_stats on itself before exiting, so cuFile's own counters (n, posix) are kept with the result.
The parent samples the host counters (nvidia-fs, EFA, CPU) around the whole run.

usage: kvikio_read.py --dir /fsx/gdsio --gpus 8 --threads 16 --task-mb 4 --compat off --out D
"""
import argparse
import glob
import json
import multiprocessing as mp
import os
import resource
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import counters  # noqa: E402


def worker(a, g, q):
    try:
        _worker(a, g, q)
    except Exception as e:  # report instead of leaving the parent waiting on the queue
        q.put({"gpu": g, "error": repr(e), "gb_per_s": 0.0, "proc_cpu_sec": 0.0})
        raise


def _worker(a, g, q):
    os.environ["CUDA_VISIBLE_DEVICES"] = str(g)
    import cupy as cp
    import kvikio
    import kvikio.defaults

    path = os.path.join(a.dir, f"f{g}")
    size = os.path.getsize(path)
    buf = cp.empty(size, dtype=cp.uint8)
    times = []
    with kvikio.defaults.set({"num_threads": a.threads, "task_size": a.task_mb << 20}):
        with kvikio.CuFile(path, "r") as f:
            pref = getattr(f, "is_compat_mode_preferred", None)
            compat = bool(pref()) if pref else None
            warm = min(size, 64 << 20)
            f.pread(buf[:warm], warm, 0).get()
            cp.cuda.runtime.deviceSynchronize()
            t0 = time.perf_counter()
            n = f.read(buf)
            cp.cuda.runtime.deviceSynchronize()
            if n != size:
                raise RuntimeError(f"short read {n} of {size}")
            times.append(time.perf_counter() - t0)
    ru = resource.getrusage(resource.RUSAGE_SELF)
    stats = ""
    tool = sorted(glob.glob("/usr/local/cuda*/gds/tools/gds_stats"))
    if tool and os.environ.get("CUFILE_STATS_LEVEL"):
        r = subprocess.run([tool[-1], "-p", str(os.getpid()), "-l", "3"], capture_output=True, text=True, errors="replace", timeout=60)
        stats = (r.stdout + r.stderr)[-4000:]
    q.put({"gpu": g, "bytes": size, "kvikio_compat_preferred": compat, "read_s": times,
           "gb_per_s": round(size * len(times) / sum(times) / 1e9, 3),
           "proc_cpu_sec": ru.ru_utime + ru.ru_stime, "gds_stats": stats})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--label", default="")
    ap.add_argument("--gpus", type=int, default=1)
    ap.add_argument("--threads", type=int, default=16)
    ap.add_argument("--task-mb", type=int, default=4)
    ap.add_argument("--compat", choices=["off", "on", "auto"], default="off")
    a = ap.parse_args()
    os.environ["KVIKIO_COMPAT_MODE"] = a.compat.upper()
    os.makedirs(a.out, exist_ok=True)
    subprocess.run(["sync"]); open("/proc/sys/vm/drop_caches", "w").write("3\n")
    ctx = mp.get_context("spawn")
    q = ctx.Queue()
    before = counters.sample()
    t0 = time.time()
    ps = [ctx.Process(target=worker, args=(a, g, q)) for g in range(a.gpus)]
    [p.start() for p in ps]
    res = [q.get() for _ in ps]
    [p.join() for p in ps]
    wall = time.time() - t0
    d = counters.delta(before, counters.sample())
    ok = all(p.exitcode == 0 for p in ps) and not any("error" in r for r in res)
    rec = {"label": a.label, "compat": a.compat, "gpus": a.gpus, "threads": a.threads, "task_mb": a.task_mb, "ok": ok,
           "gb_per_s_sum": round(sum(r["gb_per_s"] for r in res), 3), "wall_s": round(wall, 2),
           "proc_cpu_sec": round(sum(r["proc_cpu_sec"] for r in res), 2), **d, "workers": res}
    print(json.dumps({k: rec[k] for k in ("compat", "gpus", "threads", "ok", "gb_per_s_sum", "proc_cpu_sec")}), flush=True)
    with open(os.path.join(a.out, "kvikio.jsonl"), "a") as f:
        f.write(json.dumps(rec) + "\n")


if __name__ == "__main__":
    main()
