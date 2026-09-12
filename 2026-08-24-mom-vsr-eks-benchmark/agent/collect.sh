#!/usr/bin/env bash
# Copy episode results off the shared volume, and summarise what is there.
#
#   KUBE_CONTEXT=<context> ./collect.sh ../results/episodes
#
# Episodes write to a PersistentVolumeClaim rather than to their own pod, because a pod is
# not a place results can live: the first role-based episode finished and its node was
# consolidated moments later, taking the log and the record with it. This reads the volume
# through a small pod of its own, so it works whether or not any episode is still running.
set -euo pipefail

DEST="${1:-$(cd "$(dirname "$0")/.." && pwd)/results/episodes}"
NAMESPACE="${NAMESPACE:-swe-pilot}"
: "${KUBE_CONTEXT:?set KUBE_CONTEXT to the target cluster}"
KC="kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE}"
READER=episode-results-reader

$KC get pod "${READER}" >/dev/null 2>&1 || cat <<YAML | $KC apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${READER}
spec:
  containers:
    - name: reader
      image: public.ecr.aws/docker/library/busybox:1.36
      command: ["sh", "-c", "sleep infinity"]
      volumeMounts:
        - {name: results, mountPath: /results}
      resources:
        requests: {cpu: 50m, memory: 64Mi}
  volumes:
    - {name: results, persistentVolumeClaim: {claimName: episode-results}}
YAML

$KC wait --for=condition=Ready "pod/${READER}" --timeout=180s >/dev/null
mkdir -p "${DEST}"
$KC cp "${READER}:/results/." "${DEST}/" >/dev/null
echo "[OK] copied to ${DEST}"

python3 - "${DEST}" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
rows = []
for episode_file in sorted(root.glob("*/*/episode.json")):
    episode = json.loads(episode_file.read_text())
    score_file = episode_file.with_name("score.json")
    score = json.loads(score_file.read_text()) if score_file.exists() else {}
    rows.append(
        {
            "instance": episode["instance_id"],
            "policy": episode["policy"].split(" ")[0],
            "resolved": score.get("resolved"),
            "scoreable": score.get("scoreable", True),
            "usd": episode["totals"]["usd"],
            "steps": episode["totals"]["steps"],
            "tax": episode.get("switch_tax_usd") or 0.0,
            "comparable": episode.get("comparable", True),
            "stopped": episode["stopped_because"],
        }
    )

if not rows:
    print("[INFO] no episodes on the volume yet")
    raise SystemExit(0)

print(
    f"\n{'instance':<24}{'policy':<22}{'solved':>7}{'usd':>8}{'steps':>6}{'tax':>7}  why it stopped"
)
for row in rows:
    solved = "yes" if row["resolved"] else ("n/a" if not row["scoreable"] else "no")
    print(
        f"{row['instance']:<24}{row['policy']:<22}{solved:>7}{row['usd']:>8.3f}"
        f"{row['steps']:>6}{row['tax']:>7.3f}  {row['stopped'][:44]}"
    )

# Cost per solved task, which is the estimand. Reported per policy and only over episodes
# that were both scoreable and inside the runaway ceiling, because an unscoreable instance
# is not evidence that a policy failed to fix it.
print("\ncost per solved task, over comparable and scoreable episodes only:")
by_policy: dict[str, list[dict]] = {}
for row in rows:
    if row["comparable"] and row["scoreable"]:
        by_policy.setdefault(row["policy"], []).append(row)
for policy, group in sorted(by_policy.items()):
    solved = [r for r in group if r["resolved"]]
    spent = sum(r["usd"] for r in group)
    per = f"${spent / len(solved):.3f}" if solved else "no solved task yet"
    print(
        f"    {policy:<22}{len(solved)}/{len(group)} solved, ${spent:.3f} spent, {per} each"
    )
excluded = [r for r in rows if not (r["comparable"] and r["scoreable"])]
if excluded:
    print(f"\n    {len(excluded)} episodes excluded (not comparable or not scoreable)")
PY
