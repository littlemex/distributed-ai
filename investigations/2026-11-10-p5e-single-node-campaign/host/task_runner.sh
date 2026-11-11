#!/bin/bash
# Generic JSON task engine. Runs on the target host.
# Usage: task_runner.sh <tasks.json> [--env K=V ...] [--start-from ID] [--only ID] [--force]
# - Each task: {id, name, commands[], skip_if?, timeout_sec?, continue_on_error?}
# - Idempotent: a task recorded as success in the state file is skipped unless --force.
# - Every task's stdout/stderr goes to $RESULTS_DIR/logs/<investigation>/<file>/<id>.log,
#   state to $RESULTS_DIR/state/<investigation>/<file>.json.
# - A task file whose top level has "gpu": true holds an exclusive lock on the GPUs for its whole run,
#   so task files from different investigations (or another operator) never measure at the same time.
set -u
TASK_FILE="$1"
if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("gpu") else 1)' "$TASK_FILE" && [ -z "${CAMPAIGN_GPU_LOCKED:-}" ]; then
  echo "[INFO] waiting for the GPU lock (/var/lock/campaign-gpu.lock)"
  CAMPAIGN_GPU_LOCKED=1 exec flock /var/lock/campaign-gpu.lock "$0" "$@"
fi
shift
ARGS=("$@")
exec python3 - "$TASK_FILE" "${ARGS[@]}" <<'PY'
import json, os, subprocess, sys, time, datetime, pathlib
task_file = sys.argv[1]; argv = sys.argv[2:]
env = dict(os.environ); start_from = None; only = None; force = False
i = 0
while i < len(argv):
    a = argv[i]
    if a == "--env": k, v = argv[i+1].split("=", 1); env[k] = v; i += 2
    elif a == "--start-from": start_from = argv[i+1]; i += 2
    elif a == "--only": only = argv[i+1]; i += 2
    elif a == "--force": force = True; i += 1
    else: sys.exit(f"[ERROR] unknown arg {a}")
spec = json.load(open(task_file))
for k, v in spec.get("variables", {}).items():
    env.setdefault(k, str(v))
results = pathlib.Path(env.setdefault("RESULTS_DIR", "/opt/campaign/results"))
tp = pathlib.Path(task_file).resolve()
# <investigation>/tasks/<file>.json -> logs/<investigation>/<file>/
inv = tp.parent.parent.name if tp.parent.name == "tasks" else "misc"
name = tp.stem
env.setdefault("INVESTIGATION_DIR", str(tp.parent.parent))
env.setdefault("OUT", str(results / inv))
pathlib.Path(env["OUT"]).mkdir(parents=True, exist_ok=True)
logdir = results / "logs" / inv / name; logdir.mkdir(parents=True, exist_ok=True)
statedir = results / "state" / inv; statedir.mkdir(parents=True, exist_ok=True)
state_path = statedir / f"{name}.json"
state = json.load(open(state_path)) if state_path.exists() else {}
def now(): return datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).isoformat(timespec="seconds")
def save(): state_path.write_text(json.dumps(state, indent=2))
started = start_from is None
failed = False
print(f"[INFO] {now()} task file {task_file} ({spec.get('name','')})", flush=True)
for t in spec["tasks"]:
    tid = t["id"]
    if not started:
        if tid != start_from: continue
        started = True
    if only and tid != only: continue
    if not force and state.get(tid, {}).get("status") == "success":
        print(f"[SKIP] {tid} already succeeded", flush=True); continue
    if t.get("skip_if") and subprocess.run(["bash", "-c", t["skip_if"]], env=env).returncode == 0:
        print(f"[SKIP] {tid} skip_if true", flush=True)
        state[tid] = {"status": "success", "skipped": True, "at": now()}; save(); continue
    script = "set -eo pipefail\n" + "\n".join(t["commands"])
    log = logdir / f"{tid}.log"
    print(f"[RUN ] {now()} {tid}: {t.get('name','')} -> {log}", flush=True)
    t0 = time.time()
    with open(log, "a") as fh:
        fh.write(f"\n===== {now()} {tid} =====\n"); fh.flush()
        p = subprocess.Popen(["bash", "-c", script], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            deadline = t0 + t.get("timeout_sec", 6 * 3600)
            for line in p.stdout:
                fh.write(line); fh.flush(); sys.stdout.write(f"  {tid}| {line}"); sys.stdout.flush()
                if time.time() > deadline: p.kill(); fh.write("[ERROR] timeout\n")
            rc = p.wait()
        except Exception as e:
            p.kill(); rc = -1; fh.write(f"[ERROR] {e}\n")
    dt = round(time.time() - t0, 1)
    ok = rc == 0
    state[tid] = {"status": "success" if ok else "failed", "rc": rc, "sec": dt, "at": now()}; save()
    print(f"[{'OK  ' if ok else 'FAIL'}] {tid} rc={rc} {dt}s", flush=True)
    if not ok and not t.get("continue_on_error", False):
        failed = True; break
    if not ok: failed = True
sys.exit(1 if failed else 0)
PY
