#!/usr/bin/env python3
"""Record a profiling run from the files a workload left behind.

Runs beside the workload in the same Pod, in the platform's own image, so the workload's image
needs neither the accelprof package nor a compatible Python. It waits for the workload to finish,
reads the file contract, and logs one MLflow run with the captured profile as its artifacts.

Deliberate behaviours, each of which exists because the alternative makes the platform unusable:

* A malformed metrics.json does not fail the run. It is reported and the run is recorded without
  metrics, because losing a finished experiment to a typo in a throwaway script is not acceptable.
* A failed workload is still recorded, tagged status=failed. The main reason to profile something is
  that it is slow or crashing, so discarding those runs would discard the interesting ones.
* A recording failure never fails the workload's Job. The workload's own exit code decides that.
* Waiting is not sentinel-only. A SIGKILLed workload (an OOM) never writes status.json, so the
  recorder also watches its sibling container's state through the API when it is allowed to, and
  falls back to a timeout with status=unknown.
"""
from __future__ import annotations

import glob
import json
import os
import sys
import time
import urllib.request
from typing import Any

OUT = os.environ.get("ACCELPROF_OUT", "/accelprof/out")
POLL_SECONDS = 5
# The file contract's version. A status file from a newer shim is not silently reinterpreted: the run
# is recorded as failed with the reason, so a version skew between the image and a cached shim shows
# up as a visible failure instead of quietly wrong data.
SUPPORTED_SCHEMA = 1
K8S_HOST = "https://kubernetes.default.svc"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"


def log(msg: str) -> None:
    print(f"accelprof-recorder: {msg}", flush=True)


def read_json(path: str) -> dict[str, Any]:
    """Read a JSON object, tolerating anything that is not one."""
    if not os.path.exists(path):
        return {}
    try:
        value = json.load(open(path))
    except Exception as exc:  # noqa: BLE001 - any parse problem is reported, never fatal
        log(f"ignoring {path}: {exc}")
        return {}
    if not isinstance(value, dict):
        log(f"ignoring {path}: expected a JSON object, got {type(value).__name__}")
        return {}
    return value


def k8s_request(method: str, path: str, body: bytes | None = None, content_type: str | None = None) -> Any:
    """Call the API server as this Pod. Returns None when that is not possible or not permitted."""
    if not os.path.exists(f"{SA_DIR}/token"):
        return None
    try:
        import ssl

        token = open(f"{SA_DIR}/token").read().strip()
        headers = {"Authorization": f"Bearer {token}"}
        if content_type:
            headers["Content-Type"] = content_type
        req = urllib.request.Request(f"{K8S_HOST}{path}", data=body, headers=headers, method=method)
        ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
        with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
            return json.load(resp)
    except Exception as exc:  # noqa: BLE001 - absent RBAC is a supported configuration
        log(f"api call {method} {path} failed: {exc}")
        return None


def annotate_job_with_run(run_id: str) -> None:
    """Record the run id on the Job, so it can be found without reading logs.

    Best effort by design: the run is already recorded, and MLflow remains the durable way to find it
    by alias and workload id. A missing RBAC rule must not turn a recorded run into a failure.
    """
    job = os.environ.get("ACCELPROF_JOB_NAME")
    namespace = os.environ.get("ACCELPROF_POD_NAMESPACE")
    if not job or not namespace:
        return
    patch = json.dumps({"metadata": {"annotations": {"accelprof.io/run-id": run_id}}}).encode()
    result = k8s_request(
        "PATCH",
        f"/apis/batch/v1/namespaces/{namespace}/jobs/{job}",
        patch,
        "application/merge-patch+json",
    )
    log(f"annotated job/{job} with the run id" if result else f"could not annotate job/{job}; use MLflow to find the run")


def workload_container_state() -> dict[str, Any] | None:
    """The sibling container's terminated state, when the API is reachable and permitted.

    This is what turns an untrappable kill into a recorded failure instead of a timeout.
    """
    name = os.environ.get("ACCELPROF_POD_NAME")
    namespace = os.environ.get("ACCELPROF_POD_NAMESPACE")
    target = os.environ.get("ACCELPROF_WORKLOAD_CONTAINER", "workload")
    if not name or not namespace:
        return None
    pod = k8s_request("GET", f"/api/v1/namespaces/{namespace}/pods/{name}")
    if not pod:
        return None
    for status in pod.get("status", {}).get("containerStatuses", []):
        if status.get("name") == target:
            return status.get("state", {}).get("terminated")
    return None


def wait_for_workload(timeout_seconds: int) -> dict[str, Any]:
    """Return the workload's status, from its own sentinel or from the container state."""
    status_path = f"{OUT}/status.json"
    deadline = time.time() + timeout_seconds
    warned = False
    while time.time() < deadline:
        if os.path.exists(status_path):
            status = read_json(status_path)
            if status:
                return status
            return {"exit_code": 0, "reason": "completed"}
        terminated = workload_container_state()
        if terminated:
            code = int(terminated.get("exitCode", 1))
            reason = terminated.get("reason") or ("completed" if code == 0 else "failed")
            log(f"the workload container terminated without a sentinel: {reason} (exit {code})")
            return {"exit_code": code, "reason": str(reason), "profiled": False}
        if not warned:
            log(f"waiting for the workload (timeout {timeout_seconds}s)")
            warned = True
        time.sleep(POLL_SECONDS)
    log("timed out waiting for the workload")
    return {"exit_code": -1, "reason": "recorder-timeout", "profiled": False}


def collect_artifacts() -> list[str]:
    files = sorted(
        p
        for pattern in (f"{OUT}/traces/**/*", f"{OUT}/artifacts/**/*")
        for p in glob.glob(pattern, recursive=True)
        if os.path.isfile(p)
    )
    return files


def main() -> int:
    alias = os.environ["ACCELPROF_ALIAS"]
    chip = os.environ.get("ACCELPROF_CHIP", "gpu")
    region = os.environ["ACCELPROF_REGION"]
    bucket = os.environ["ACCELPROF_TRACE_BUCKET"]
    tracking_uri = os.environ["ACCELPROF_TRACKING_URI"]
    workload_id = os.environ.get("ACCELPROF_WORKLOAD_ID") or os.environ.get("ACCELPROF_POD_NAME", "unknown")
    timeout_seconds = int(os.environ.get("ACCELPROF_RECORDER_TIMEOUT", "86400"))
    record_on_failure = os.environ.get("ACCELPROF_RECORD_ON_FAILURE", "true").lower() == "true"

    status = wait_for_workload(timeout_seconds)
    schema = int(status.get("schema_version", SUPPORTED_SCHEMA))
    unsupported = schema > SUPPORTED_SCHEMA
    if unsupported:
        log(f"status.json declares contract version {schema}, newer than the supported {SUPPORTED_SCHEMA}")
    exit_code = int(status.get("exit_code", -1))
    failed = exit_code != 0 or unsupported
    if failed and not record_on_failure:
        log(f"the workload failed ({status.get('reason')}) and recordOnFailure is off; recording nothing")
        return 0

    artifacts = collect_artifacts()
    metrics = {k: v for k, v in read_json(f"{OUT}/metrics.json").items() if isinstance(v, (int, float))}
    params = read_json(f"{OUT}/params.json")
    tags = {str(k): str(v) for k, v in read_json(f"{OUT}/tags.json").items()}

    for source in ("ACCELPROF_PARAMS", "ACCELPROF_TAGS"):
        extra = os.environ.get(source, "").strip()
        if not extra:
            continue
        parsed = {}
        try:
            parsed = json.loads(extra)
        except Exception as exc:  # noqa: BLE001
            log(f"ignoring {source}: {exc}")
        if source == "ACCELPROF_PARAMS":
            params.update({str(k): v for k, v in parsed.items()})
        else:
            tags.update({str(k): str(v) for k, v in parsed.items()})

    tags.update(
        {
            "status": "ok" if not failed else "failed",
            "exit_reason": "unsupported-contract" if unsupported else str(status.get("reason", "")),
            "contract_version": str(schema),
            "profiled": str(bool(status.get("profiled", False))).lower(),
            "profiled_ranks": os.environ.get("ACCELPROF_PROFILE_RANKS", "0"),
            "profile_mode": os.environ.get("ACCELPROF_PROFILE_MODE", "none"),
            "pod": os.environ.get("ACCELPROF_POD_NAME", ""),
        }
    )
    if os.environ.get("ACCELPROF_WORLD_SIZE"):
        tags["world_size"] = os.environ["ACCELPROF_WORLD_SIZE"]
    metrics["exit_code"] = exit_code

    log(f"recording alias={alias} workload_id={workload_id} artifacts={len(artifacts)}")
    from experiment_store import ExperimentStore

    store = ExperimentStore.build(region=region, trace_bucket=bucket, tracking_uri=tracking_uri)
    run_id = store.log(
        alias,
        chip=chip,
        region=region,
        workload_id=workload_id,
        metrics=metrics or None,
        params=params or None,
        tags=tags or None,
        artifacts=artifacts,
    )
    # The client greps this line, so keep the shape stable.
    print(f"ACCELPROF_RUN_ID={run_id}", flush=True)
    annotate_job_with_run(run_id)
    log(f"recorded run {run_id}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - a recording failure must not fail the workload's Job
        log(f"recording failed: {type(exc).__name__}: {exc}")
        sys.exit(0)
