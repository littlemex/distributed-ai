"""Record when each checkpoint step directory appears, grows and is complete.

Polls <root>/step-*/ every --interval seconds until --stop-file exists. A save is complete when its
metadata file is present (".metadata" for DCP; torch_checkpointing's own metadata file name is read
from the library). Writes one JSON line per step to --out:
  {"step", "first_seen", "metadata_seen", "bytes", "files"}   (times are Unix seconds)
This measures write completion on the storage itself, independent of what the trainer logs.
"""
import argparse
import glob
import json
import os
import time

NAMES = {".metadata"}
try:
    from torch_checkpointing.metadata_serialization import METADATA_FILE_NAME
    NAMES.add(METADATA_FILE_NAME)
except Exception:
    pass


def du(path):
    total = n = 0
    for dp, _, fs in os.walk(path):
        for f in fs:
            try:
                total += os.path.getsize(os.path.join(dp, f)); n += 1
            except OSError:
                pass
    return total, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--stop-file", required=True)
    ap.add_argument("--interval", type=float, default=0.2)
    a = ap.parse_args()
    seen = {}
    while True:
        now = time.time()
        for d in glob.glob(os.path.join(a.root, "step-*")):
            s = seen.setdefault(d, {"step": int(d.rsplit("-", 1)[1]), "first_seen": now, "metadata_seen": None})
            if s["metadata_seen"] is None and any(os.path.exists(os.path.join(d, n)) for n in NAMES):
                s["metadata_seen"] = now
        if os.path.exists(a.stop_file):
            break
        time.sleep(a.interval)
    with open(a.out, "w") as f:
        for d, s in sorted(seen.items(), key=lambda kv: kv[1]["step"]):
            s["bytes"], s["files"] = du(d)
            f.write(json.dumps(s) + "\n")


if __name__ == "__main__":
    main()
