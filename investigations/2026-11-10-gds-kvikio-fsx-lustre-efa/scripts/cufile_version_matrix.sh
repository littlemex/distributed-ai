#!/bin/bash
# The same strict (no compat fallback) read of /fsx/gdsio/f0 with every libcufile on the host, once
# through gdsio and once through KvikIO. Each line of <out>/matrix.txt records the cuFile release that
# actually ran (from its own log), the nvidia-fs read counter before and after, the result, and whether
# cuFile decided to fall back to compat mode or refused the file.
# Usage: cufile_version_matrix.sh <out dir> <strict cufile.json>   (needs VENV and INVESTIGATION_DIR)
set -u
D=$1; STRICT=$2
mkdir -p "$D"; : > "$D/matrix.txt"
T=$(ls -d /usr/local/cuda*/gds/tools | sort -V | tail -1)
LIBS="$(ls /usr/local/cuda-*/targets/x86_64-linux/lib/libcufile.so.[0-9]*.* 2>/dev/null) $(ls "$VENV"/lib/python3.12/site-packages/nvidia/cu*/lib/libcufile.so.0 2>/dev/null)"
nvfs_n() { grep -E '^Reads' /proc/driver/nvidia-fs/stats | grep -oE 'n=[0-9]+' | head -1 | cut -d= -f2; }
for L in $LIBS; do
  for TOOL in gdsio kvikio; do
    rm -rf /tmp/cflog && mkdir -p /tmp/cflog
    python3 - "$STRICT" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c["logging"]["dir"] = "/tmp/cflog"
json.dump(c, open("/tmp/strict-log.json", "w"))
PY
    sync; echo 3 > /proc/sys/vm/drop_caches
    B=$(nvfs_n)
    if [ "$TOOL" = gdsio ]; then
      OUTL=$(CUFILE_ENV_PATH_JSON=/tmp/strict-log.json LD_PRELOAD=$L timeout 120 "$T/gdsio" -f /fsx/gdsio/f0 -d 0 -w 16 -s 8G -i 4096K -x 0 -I 0 -T 15 2>&1)
      R=$(echo "$OUTL" | grep -oE 'Throughput: [0-9.]+ GiB/sec|[Ee]rror[^,]*' | head -1)
    else
      OUTL=$(CUFILE_ENV_PATH_JSON=/tmp/strict-log.json LD_PRELOAD=$L "$VENV/bin/python" "$INVESTIGATION_DIR/scripts/kvikio_read.py" --label "cufile-$(basename "$L")" --dir /fsx/gdsio --out "$D" --gpus 1 --threads 16 --compat off 2>&1)
      R=$(echo "$OUTL" | tail -1); echo "$OUTL" | grep -E "Error|error" | tail -3 > "$D/kvikio-err-$(basename "$L").txt"
    fi
    A=$(nvfs_n)
    V=$(grep -ohE 'GDS release version: [0-9.]+' /tmp/cflog/* 2>/dev/null | head -1)
    C=$(grep -ohE 'activating compatibility mode[^@]*|file checks failed|not supported on current file' /tmp/cflog/* 2>/dev/null | sort -u | tr '\n' ';')
    echo "lib=$L tool=$TOOL | $V | nvfs reads $B -> $A | $R | $C" | tee -a "$D/matrix.txt"
    mkdir -p "$D/logs/$(basename "$L")-$TOOL" && cp /tmp/cflog/* "$D/logs/$(basename "$L")-$TOOL/" 2>/dev/null
  done
done
