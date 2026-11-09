#!/bin/bash
# Run one checkpoint recipe against one storage target and keep the timestamped log and the watcher's
# record. Usage: run_variant.sh <recipe> <target dir> <out dir>
# Needs TORCHTITAN_SRC (repository checkout) and VENV.
set -euo pipefail
RECIPE=$1; TARGET=$2; OUTD=$3
RUN=$TARGET/ckpt/$RECIPE
mkdir -p "$OUTD"; rm -rf "$RUN"; mkdir -p "$RUN"
STOP=$(mktemp -u)
"$VENV/bin/python" "$(dirname "$0")/watch_ckpt.py" --root "$RUN/checkpoint" --out "$OUTD/watch.jsonl" --stop-file "$STOP" &
WATCH=$!
cd "$TORCHTITAN_SRC"
sync; echo 3 > /proc/sys/vm/drop_caches
set +e
PATH=$VENV/bin:$PATH PYTHONPATH=$(dirname "$0"):${PYTHONPATH:-} NGPU=8 MODULE=ckpt_recipes CONFIG=$RECIPE \
  ./run_train.sh --output-dir "$RUN" 2>&1 | "$VENV/bin/python" -u -c '
import sys, time
for line in sys.stdin:
    sys.stdout.write(f"{time.time():.3f} {line}"); sys.stdout.flush()' > "$OUTD/train.log"
RC=${PIPESTATUS[0]}
set -e
# DCP async writers may still be flushing when the trainer exits; give them a moment.
sleep 20; touch "$STOP"; wait $WATCH || true
du -sb "$RUN/checkpoint" > "$OUTD/du.txt" 2>&1 || true
echo "rc=$RC" > "$OUTD/rc.txt"
rm -rf "$RUN"
exit $RC
