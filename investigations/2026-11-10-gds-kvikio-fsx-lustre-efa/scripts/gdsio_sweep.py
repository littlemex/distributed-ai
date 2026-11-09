"""Run gdsio over a matrix and record throughput, CPU time and the path counters for every cell.

Each cell runs one gdsio process per GPU in parallel (GPU i reads its own file f<i>), so "gpus=8" is
the aggregate of eight readers. Results append to <out>/gdsio.jsonl, one JSON object per cell.

Modes:
  gds-strict   xfer 0 (GPU direct), cufile strict.json: a success means the direct path was used
  gds-default  xfer 0, cufile default.json: cuFile may fall back to compat on its own
  gds-compat   xfer 0, CUFILE_FORCE_COMPAT_MODE=true: cuFile bounces every read through CPU memory
  cpu-gpu      xfer 2 (CPU_GPU): gdsio reads into pinned CPU memory and copies to the GPU itself

usage: gdsio_sweep.py --dir /fsx/gdsio --cufile-dir D --out D [--modes ...] [--gpus 1,8]
                      [--threads 1,4,16] [--io-kb 1024,4096,16384] [--size 16G] [--seconds 20]
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import counters  # noqa: E402

MODES = {
    "gds-strict": (0, "strict.json", {}),
    "gds-default": (0, "default.json", {}),
    "gds-compat": (0, "default.json", {"CUFILE_FORCE_COMPAT_MODE": "true"}),
    "cpu-gpu": (2, "default.json", {}),
}


def gdsio_bin():
    tools = sorted(glob.glob("/usr/local/cuda*/gds/tools/gdsio"))
    if not tools:
        sys.exit("[ERROR] gdsio not found under /usr/local/cuda*/gds/tools")
    return tools[-1]


def drop_caches():
    subprocess.run(["sync"], check=False)
    with open("/proc/sys/vm/drop_caches", "w") as f:
        f.write("3\n")


def run_cell(a, mode, gpus, threads, io_kb):
    xfer, cfg, extra = MODES[mode]
    env = {**os.environ, "CUFILE_ENV_PATH_JSON": os.path.join(a.cufile_dir, cfg), **extra}
    drop_caches()
    before = counters.sample()
    t0 = time.time()
    procs = []
    for g in range(gpus):
        cmd = [gdsio_bin(), "-f", os.path.join(a.dir, f"f{g}"), "-d", str(g), "-w", str(threads),
               "-s", a.size, "-i", f"{io_kb}K", "-x", str(xfer), "-I", "0", "-T", str(a.seconds)]
        procs.append(subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True))
    outs = [p.communicate(timeout=a.seconds * 6 + 120)[0] for p in procs]
    wall = time.time() - t0
    d = counters.delta(before, counters.sample())
    gib = [float(m.group(1)) for o in outs for m in [re.search(r"Throughput:\s*([\d.]+)\s*GiB/sec", o)] if m]
    ok = len(gib) == gpus and all(p.returncode == 0 for p in procs)
    rec = {"mode": mode, "xfer": xfer, "gpus": gpus, "threads": threads, "io_kb": io_kb, "ok": ok,
           "gib_per_s": round(sum(gib), 3) if ok else None, "wall_s": round(wall, 2),
           "cpu_cores": round(d.get("cpu_busy_sec", 0) / wall, 2), **d,
           "tail": [o.strip().splitlines()[-2:] for o in outs]}
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--cufile-dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--label", default="")
    ap.add_argument("--modes", default="gds-strict,gds-default,gds-compat,cpu-gpu")
    ap.add_argument("--gpus", default="1,8")
    ap.add_argument("--threads", default="1,4,16")
    ap.add_argument("--io-kb", default="1024,4096,16384")
    ap.add_argument("--size", default="16G")
    ap.add_argument("--seconds", type=int, default=20)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    path = os.path.join(a.out, "gdsio.jsonl")
    for mode in a.modes.split(","):
        for gpus in map(int, a.gpus.split(",")):
            for th in map(int, a.threads.split(",")):
                for io in map(int, a.io_kb.split(",")):
                    rec = {"label": a.label, "dir": a.dir, **run_cell(a, mode, gpus, th, io)}
                    print(json.dumps({k: rec[k] for k in ("mode", "gpus", "threads", "io_kb", "ok", "gib_per_s", "cpu_cores")}), flush=True)
                    with open(path, "a") as f:
                        f.write(json.dumps(rec) + "\n")


if __name__ == "__main__":
    main()
