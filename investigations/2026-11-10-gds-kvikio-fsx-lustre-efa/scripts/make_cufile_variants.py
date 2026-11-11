"""Write cufile.json variants from the stock file (comments stripped).

- default: stock settings, statistics on, INFO logs to /var/log/cufile.
- strict:  allow_compat_mode=false, so cuFile returns an error instead of bouncing through CPU memory.
           A strict read that succeeds proves the direct path was taken.
The CPU-staged baseline is the default file with CUFILE_FORCE_COMPAT_MODE=true in the environment
(set by the sweep), which makes cuFile bounce every read through CPU memory.

usage: make_cufile_variants.py <stock cufile.json> <out dir>
"""
import json
import re
import sys
from pathlib import Path

stock, outdir = Path(sys.argv[1]), Path(sys.argv[2])
outdir.mkdir(parents=True, exist_ok=True)
txt = re.sub(r"(?m)^\s*//.*$", "", stock.read_text())
txt = re.sub(r"(?<=[,{\[\s])//[^\n\"]*$", "", txt, flags=re.M)
cfg = json.loads(txt)
variants = {
    "default": {},
    "strict": {"allow_compat_mode": False},
}
for name, props in variants.items():
    c = json.loads(json.dumps(cfg))
    c.setdefault("logging", {}).update({"dir": "/var/log/cufile", "level": "INFO"})
    c.setdefault("profile", {})["cufile_stats"] = 3
    c.setdefault("properties", {}).update(props)
    (outdir / f"{name}.json").write_text(json.dumps(c, indent=1))
    print("wrote", outdir / f"{name}.json", props)
