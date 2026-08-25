#!/usr/bin/env python3
"""Report producer Jobs that finished without a recording.

The platform deliberately has no controller: a producer Job records its own run from inside its Pod.
That leaves one gap no in-Pod component can close — if the Pod disappears before the recorder runs
(an evicted Pod, a drained node, a recorder that was itself killed), the workload finished and
nothing was recorded, and no failure is visible anywhere.

This is monitoring, not reconciliation: it looks for finished Jobs that carry no run id and reports
them, exiting non-zero so the CronJob's own status makes the gap visible. It never deletes, resubmits
or repairs anything, because guessing what a vanished workload did is worse than saying it is missing.
"""
from __future__ import annotations

import json
import os
import ssl
import sys
import urllib.request

K8S_HOST = "https://kubernetes.default.svc"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
LABEL = "app.kubernetes.io/name=profiling-producer"
RUN_ID_ANNOTATION = "accelprof.io/run-id"


def api(path: str) -> dict:
    token = open(f"{SA_DIR}/token").read().strip()
    req = urllib.request.Request(f"{K8S_HOST}{path}", headers={"Authorization": f"Bearer {token}"})
    ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
    with urllib.request.urlopen(req, timeout=20, context=ctx) as resp:
        return json.load(resp)


def finished(job: dict) -> str | None:
    for condition in job.get("status", {}).get("conditions", []):
        if condition.get("status") == "True" and condition.get("type") in ("Complete", "Failed"):
            return condition["type"]
    return None


def main() -> int:
    namespace = os.environ.get("POD_NAMESPACE") or open(f"{SA_DIR}/namespace").read().strip()
    jobs = api(f"/apis/batch/v1/namespaces/{namespace}/jobs?labelSelector={LABEL}").get("items", [])
    orphans = []
    for job in jobs:
        state = finished(job)
        if not state:
            continue
        meta = job.get("metadata", {})
        if meta.get("annotations", {}).get(RUN_ID_ANNOTATION):
            continue
        orphans.append(
            {
                "job": meta.get("name"),
                "state": state,
                "alias": meta.get("labels", {}).get("accelprof.io/alias"),
                "workload_id": meta.get("labels", {}).get("accelprof.io/workload-id"),
            }
        )

    print(f"namespace={namespace} producer_jobs={len(jobs)} unrecorded={len(orphans)}", flush=True)
    for orphan in orphans:
        print(
            "unrecorded: job={job} state={state} alias={alias} workload_id={workload_id}".format(**orphan),
            flush=True,
        )
    if orphans:
        print(
            "these workloads finished with no run recorded; the usual cause is the Pod disappearing "
            "before its recorder ran (eviction, node drain, a killed recorder). Inspect the Job's "
            "events, then re-run the workload if its result is still wanted.",
            flush=True,
        )
        # A non-zero exit makes the CronJob's last run show as failed, which is the signal.
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - a broken check must be visibly broken, not silent
        print(f"orphan check failed: {type(exc).__name__}: {exc}", flush=True)
        sys.exit(2)
