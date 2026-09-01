#!/usr/bin/env python3
"""Every register_test must name a function that one of the sourced case files defines.

run-tests.sh sources its case files by name rather than by glob, which keeps the order under control
but means a new file can be registered and never loaded. The runner then calls a name that does not
exist, and the case reports exit 127 — a failure that looks like the test found something.
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
runner = (root / "run-tests.sh").read_text()
sourced = set(re.findall(r'source "\$SCRIPT_DIR/cases/([^"]+)"', runner))
if not sourced:
    print("run-tests.sh sources no case files; this check is looking in the wrong place", file=sys.stderr)
    sys.exit(2)

defined = {}
for f in sorted((root / "cases").glob("*.sh")):
    for m in re.finditer(r"^(test_[A-Za-z0-9_]+)\(\)", f.read_text(), re.M):
        defined.setdefault(m.group(1), set()).add(f.name)

bad = []
for m in re.finditer(r"^\s*register_test\s+(\S+)\s+(\S+)", (root / "registry.sh").read_text(), re.M):
    name, func = m.group(1), m.group(2)
    files = defined.get(func)
    if not files:
        bad.append("%s: %s() is not defined in any cases/*.sh" % (name, func))
    elif not (files & sourced):
        bad.append("%s: %s() lives in %s, which run-tests.sh does not source"
                   % (name, func, ", ".join(sorted(files))))

for b in bad:
    print(b, file=sys.stderr)
sys.exit(1 if bad else 0)
