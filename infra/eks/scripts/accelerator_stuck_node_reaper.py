#!/usr/bin/env python3
"""
Recover Karpenter NodeClaims stuck in termination because their node went NotReady.

Safety invariants:
  1. Act only on opt-in pools from config.json.
  2. Act only on NodeClaims that are ALREADY deleting and still carry
     karpenter.sh/termination.
  3. Refuse to act unless the backing node is still Ready!=True in a kubelet-dead state
     beyond the configured threshold.
  4. Terminate the EC2 instance and wait for it to be gone BEFORE removing the finalizer.

The EC2 path stays stdlib-only: it uses hand-written SigV4 + Query API XML so the image
does not need boto3 or a runtime pip install in a minimal, possibly air-gapped environment.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


SERVICEACCOUNT_CA = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
SERVICEACCOUNT_TOKEN = "/var/run/secrets/kubernetes.io/serviceaccount/token"

# Only "NodeStatusUnknown" proves the kubelet stopped posting status: the node controller sets it
# after the kubelet misses its heartbeat, which is exactly the "kubelet is dead, cannot self-drain"
# case this reaper exists for. "KubeletNotReady" is deliberately excluded — a *live* kubelet reports
# Ready=False/KubeletNotReady for recoverable local faults (CNI, container runtime, disk pressure),
# and terminating that node would destroy a still-healthy instance. Keep this set minimal and
# fail-closed: an unrecognized reason is never treated as reapable.
KUBELET_DEAD_NOTREADY_REASONS = {"NodeStatusUnknown"}


def log(message: str) -> None:
    stamp = dt.datetime.now(dt.timezone.utc).isoformat()
    print(f"{stamp} {message}", flush=True)


def parse_rfc3339(value: str) -> dt.datetime:
    if value.endswith("Z"):
        value = f"{value[:-1]}+00:00"
    return dt.datetime.fromisoformat(value)


def parse_duration(value: str) -> int:
    multipliers = {"s": 1, "m": 60, "h": 3600}
    if len(value) < 2 or value[-1] not in multipliers or not value[:-1].isdigit():
        raise ValueError(f"invalid duration {value!r}; expected <int>[smh]")
    return int(value[:-1]) * multipliers[value[-1]]


def parse_instance_id(provider_id: str | None) -> str | None:
    if not provider_id:
        return None
    return provider_id.rsplit("/", 1)[-1] or None


def strip_namespaces(root: ET.Element) -> ET.Element:
    for node in root.iter():
        if "}" in node.tag:
            node.tag = node.tag.split("}", 1)[1]
    return root


class KubernetesApiError(Exception):
    def __init__(self, status_code: int, body: str):
        super().__init__(f"kubernetes api {status_code}: {body}")
        self.status_code = status_code
        self.body = body


class AwsApiError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


class KubernetesApi:
    def __init__(self) -> None:
        host = os.environ["KUBERNETES_SERVICE_HOST"]
        port = os.environ.get("KUBERNETES_SERVICE_PORT_HTTPS", os.environ.get("KUBERNETES_SERVICE_PORT", "443"))
        self.base_url = f"https://{host}:{port}"
        with open(SERVICEACCOUNT_TOKEN, "r", encoding="utf-8") as fh:
            self.token = fh.read().strip()
        self.ssl_context = ssl.create_default_context(cafile=SERVICEACCOUNT_CA)

    def _request(
        self,
        method: str,
        path: str,
        body: str | None = None,
        content_type: str = "application/json",
    ) -> dict | None:
        payload = body.encode("utf-8") if body is not None else None
        headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {self.token}",
        }
        if payload is not None:
            headers["Content-Type"] = content_type
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=payload,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, context=self.ssl_context, timeout=30) as response:
                response_body = response.read()
        except urllib.error.HTTPError as exc:
            body_text = exc.read().decode("utf-8", errors="replace")
            raise KubernetesApiError(exc.code, body_text) from exc
        if not response_body:
            return None
        return json.loads(response_body.decode("utf-8"))

    def list_nodeclaims(self) -> list[dict]:
        payload = self._request("GET", "/apis/karpenter.sh/v1/nodeclaims")
        return payload.get("items", []) if payload else []

    def get_nodeclaim(self, name: str) -> dict | None:
        try:
            return self._request("GET", f"/apis/karpenter.sh/v1/nodeclaims/{urllib.parse.quote(name, safe='')}")
        except KubernetesApiError as exc:
            if exc.status_code == 404:
                return None
            raise

    def get_node(self, name: str) -> dict | None:
        try:
            return self._request("GET", f"/api/v1/nodes/{urllib.parse.quote(name, safe='')}")
        except KubernetesApiError as exc:
            if exc.status_code == 404:
                return None
            raise

    def patch_nodeclaim_finalizers(
        self, name: str, finalizers: list[str], resource_version: str | None = None
    ) -> None:
        # Include resourceVersion so the merge-patch is a compare-and-swap: if another controller
        # added a finalizer between our GET and this PATCH, the API server rejects it with 409 and we
        # retry on the next run instead of silently clobbering that controller's finalizer.
        metadata: dict = {"finalizers": finalizers}
        if resource_version is not None:
            metadata["resourceVersion"] = resource_version
        body = json.dumps({"metadata": metadata})
        self._request(
            "PATCH",
            f"/apis/karpenter.sh/v1/nodeclaims/{urllib.parse.quote(name, safe='')}",
            body=body,
            content_type="application/merge-patch+json",
        )

    def delete_node(self, name: str) -> None:
        try:
            self._request("DELETE", f"/api/v1/nodes/{urllib.parse.quote(name, safe='')}")
        except KubernetesApiError as exc:
            if exc.status_code != 404:
                raise


class PodIdentityCredentialsProvider:
    def __init__(self) -> None:
        self.credentials_uri = os.environ["AWS_CONTAINER_CREDENTIALS_FULL_URI"]
        self.authorization = os.environ.get("AWS_CONTAINER_AUTHORIZATION_TOKEN")
        token_file = os.environ.get("AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE")
        if token_file and os.path.exists(token_file):
            # Read the pod identity auth token once at startup; a reaper run is far shorter than its TTL.
            with open(token_file, "r", encoding="utf-8") as fh:
                self.authorization = fh.read().strip()
        self.cached: dict | None = None

    def get(self) -> dict:
        now = dt.datetime.now(dt.timezone.utc)
        if self.cached and now + dt.timedelta(minutes=5) < self.cached["expiration"]:
            return self.cached

        headers = {}
        if self.authorization:
            headers["Authorization"] = self.authorization

        request = urllib.request.Request(self.credentials_uri, headers=headers, method="GET")
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = json.loads(response.read().decode("utf-8"))

        self.cached = {
            "access_key": payload["AccessKeyId"],
            "secret_key": payload["SecretAccessKey"],
            "session_token": payload["Token"],
            "expiration": parse_rfc3339(payload["Expiration"]),
        }
        return self.cached


class Ec2Api:
    """Call the EC2 Query API directly to keep the reaper image stdlib-only.

    That avoids a boto3 dependency or runtime pip install in a minimal, possibly air-gapped image.
    """

    def __init__(self, region: str, credentials: PodIdentityCredentialsProvider) -> None:
        self.region = region
        self.credentials = credentials
        self.host = f"ec2.{region}.amazonaws.com"
        self.endpoint = f"https://{self.host}/"

    @staticmethod
    def _sign(key: bytes, message: str) -> bytes:
        return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()

    def _request(self, action: str, params: dict[str, str]) -> ET.Element:
        creds = self.credentials.get()
        body = urllib.parse.urlencode({"Action": action, "Version": "2016-11-15", **params})
        now = dt.datetime.now(dt.timezone.utc)
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        date_stamp = now.strftime("%Y%m%d")

        canonical_headers = (
            "content-type:application/x-www-form-urlencoded; charset=utf-8\n"
            f"host:{self.host}\n"
            f"x-amz-date:{amz_date}\n"
            f"x-amz-security-token:{creds['session_token']}\n"
        )
        signed_headers = "content-type;host;x-amz-date;x-amz-security-token"
        payload_hash = hashlib.sha256(body.encode("utf-8")).hexdigest()
        canonical_request = "\n".join([
            "POST",
            "/",
            "",
            canonical_headers,
            signed_headers,
            payload_hash,
        ])

        credential_scope = f"{date_stamp}/{self.region}/ec2/aws4_request"
        string_to_sign = "\n".join([
            "AWS4-HMAC-SHA256",
            amz_date,
            credential_scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ])

        signing_key = self._sign(
            self._sign(
                self._sign(
                    self._sign(f"AWS4{creds['secret_key']}".encode("utf-8"), date_stamp),
                    self.region,
                ),
                "ec2",
            ),
            "aws4_request",
        )
        signature = hmac.new(signing_key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
        authorization = (
            "AWS4-HMAC-SHA256 "
            f"Credential={creds['access_key']}/{credential_scope}, "
            f"SignedHeaders={signed_headers}, Signature={signature}"
        )

        headers = {
            "Authorization": authorization,
            "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
            "Host": self.host,
            "X-Amz-Date": amz_date,
            "X-Amz-Security-Token": creds["session_token"],
        }

        request = urllib.request.Request(
            self.endpoint,
            data=body.encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return strip_namespaces(ET.fromstring(response.read()))
        except urllib.error.HTTPError as exc:
            body_bytes = exc.read()
            try:
                root = strip_namespaces(ET.fromstring(body_bytes))
                code = root.findtext(".//Code") or f"HTTP{exc.code}"
                message = root.findtext(".//Message") or body_bytes.decode("utf-8", errors="replace")
            except ET.ParseError:
                code = f"HTTP{exc.code}"
                message = body_bytes.decode("utf-8", errors="replace")
            raise AwsApiError(code, message) from exc

    def describe_instance_state(self, instance_id: str) -> str | None:
        """Return the EC2 instance state name, or None only when the instance no longer exists.

        The None return is reserved for a confirmed absence (InvalidInstanceID.NotFound). A 200
        response whose state cannot be parsed must NOT collapse to None — the caller treats None as
        "gone, safe to clear the finalizer", so an unparseable response has to fail closed rather
        than be mistaken for a terminated instance.
        """
        try:
            root = self._request("DescribeInstances", {"InstanceId.1": instance_id})
        except AwsApiError as exc:
            if exc.code == "InvalidInstanceID.NotFound":
                return None
            raise
        state = root.findtext(".//instancesSet/item/instanceState/name")
        if state is None:
            raise AwsApiError(
                "UnparseableInstanceState",
                f"DescribeInstances for {instance_id} returned 200 but no instanceState/name; "
                "refusing to treat as terminated",
            )
        return state

    def describe_instance_status(self, instance_id: str) -> dict[str, str]:
        try:
            root = self._request(
                "DescribeInstanceStatus",
                {"InstanceId.1": instance_id, "IncludeAllInstances": "true"},
            )
        except AwsApiError as exc:
            if exc.code == "InvalidInstanceID.NotFound":
                return {"instance": "missing", "system": "missing"}
            raise

        item = root.find(".//instanceStatusSet/item")
        if item is None:
            return {"instance": "unknown", "system": "unknown"}
        return {
            "instance": item.findtext("instanceStatus/status") or "unknown",
            "system": item.findtext("systemStatus/status") or "unknown",
        }

    def terminate_instance(self, instance_id: str) -> None:
        try:
            self._request("TerminateInstances", {"InstanceId.1": instance_id})
        except AwsApiError as exc:
            if exc.code != "InvalidInstanceID.NotFound":
                raise


def nodeclaim_is_stuck(nodeclaim: dict, finalizer: str) -> bool:
    metadata = nodeclaim.get("metadata", {})
    return bool(metadata.get("deletionTimestamp")) and finalizer in metadata.get("finalizers", [])


def node_pool_name(nodeclaim: dict, node: dict | None) -> str | None:
    if node:
        labels = node.get("metadata", {}).get("labels", {})
        # node-role is the module-owned stable selector label; keep it as a fallback in case a
        # deleting Node never got karpenter.sh/nodepool before the kubelet stopped reporting.
        return labels.get("karpenter.sh/nodepool") or labels.get("node-role")
    labels = nodeclaim.get("metadata", {}).get("labels", {})
    return labels.get("karpenter.sh/nodepool")


def ready_condition(node: dict) -> dict | None:
    for condition in node.get("status", {}).get("conditions", []):
        if condition.get("type") == "Ready":
            return condition
    return None


def node_is_reapable(node: dict, threshold_seconds: int) -> tuple[bool, str]:
    condition = ready_condition(node)
    if not condition:
        return False, "missing Ready condition"

    if condition.get("status") == "True":
        return False, "Ready=True"

    # Fail closed: only the explicit kubelet-dead reason qualifies. An empty or unrecognized reason
    # is treated as "not proven dead" so a live-but-unhealthy node is never terminated.
    reason = condition.get("reason", "")
    if reason not in KUBELET_DEAD_NOTREADY_REASONS:
        return False, f"Ready reason {reason!r} is not a proven kubelet-dead state"

    last_transition = condition.get("lastTransitionTime")
    if not last_transition:
        return False, "missing Ready.lastTransitionTime"

    age_seconds = int((dt.datetime.now(dt.timezone.utc) - parse_rfc3339(last_transition)).total_seconds())
    if age_seconds < threshold_seconds:
        return False, f"NotReady for {age_seconds}s < threshold {threshold_seconds}s"

    return True, f"Ready={condition.get('status')} reason={reason or 'n/a'} age={age_seconds}s"


def clear_finalizer_if_safe(
    kube: KubernetesApi,
    ec2: Ec2Api,
    nodeclaim_name: str,
    node_name: str | None,
    provider_id: str | None,
    finalizer: str,
    dry_run: bool,
) -> None:
    instance_id = parse_instance_id(provider_id)
    if not instance_id:
        log(f"{nodeclaim_name}: node object is gone but providerID is missing; leaving finalizer intact")
        return

    state = ec2.describe_instance_state(instance_id)
    if state not in (None, "terminated"):
        log(
            f"{nodeclaim_name}: node object is gone but instance {instance_id} is still {state}; "
            "refusing to clear the finalizer"
        )
        return

    if dry_run:
        log(
            f"{nodeclaim_name}: DRY-RUN backing instance {instance_id} is gone; would clear "
            f"{finalizer} and delete Node {node_name or '<none>'} — taking no action"
        )
        return

    current = kube.get_nodeclaim(nodeclaim_name)
    if current and finalizer in current.get("metadata", {}).get("finalizers", []):
        remaining = [value for value in current["metadata"]["finalizers"] if value != finalizer]
        kube.patch_nodeclaim_finalizers(
            nodeclaim_name, remaining, current["metadata"].get("resourceVersion")
        )
        log(f"{nodeclaim_name}: backing instance {instance_id} is already gone; cleared {finalizer}")

    if node_name:
        kube.delete_node(node_name)


def wait_for_termination(ec2: Ec2Api, instance_id: str, timeout_seconds: int, poll_interval_seconds: int) -> bool:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        state = ec2.describe_instance_state(instance_id)
        if state in (None, "terminated"):
            return True
        time.sleep(poll_interval_seconds)
    return False


def process_nodeclaim(kube: KubernetesApi, ec2: Ec2Api, config: dict, nodeclaim: dict) -> bool:
    """Return True only when an error/timeout occurred and the next CronJob run should retry."""

    finalizer = config["karpenter_termination_finalizer"]
    name = nodeclaim["metadata"]["name"]
    if not nodeclaim_is_stuck(nodeclaim, finalizer):
        return False

    node_name = nodeclaim.get("status", {}).get("nodeName")
    node = kube.get_node(node_name) if node_name else None
    pool_name = node_pool_name(nodeclaim, node)
    if pool_name not in config["pools"]:
        return False

    threshold_seconds = parse_duration(config["pools"][pool_name]["notready_threshold"])

    if node is None:
        clear_finalizer_if_safe(
            kube,
            ec2,
            name,
            node_name,
            nodeclaim.get("status", {}).get("providerID"),
            finalizer,
            config.get("dry_run", False),
        )
        return False

    reapable, reason = node_is_reapable(node, threshold_seconds)
    if not reapable:
        return False

    current = kube.get_nodeclaim(name)
    if not current or not nodeclaim_is_stuck(current, finalizer):
        return False

    node = kube.get_node(node_name) if node_name else None
    if node is None:
        clear_finalizer_if_safe(
            kube,
            ec2,
            name,
            node_name,
            current.get("status", {}).get("providerID"),
            finalizer,
            config.get("dry_run", False),
        )
        return False

    reapable, reason = node_is_reapable(node, threshold_seconds)
    if not reapable:
        return False

    provider_id = node.get("spec", {}).get("providerID") or current.get("status", {}).get("providerID")
    instance_id = parse_instance_id(provider_id)
    if not instance_id:
        log(f"{name}: pool={pool_name} node={node_name} has no providerID; cannot terminate safely")
        return False

    status = ec2.describe_instance_status(instance_id)
    state = ec2.describe_instance_state(instance_id)
    if config.get("dry_run"):
        log(
            f"{name}: DRY-RUN would terminate pool={pool_name} node={node_name} instance={instance_id} "
            f"({reason}; ec2_state={state}, instance_status={status['instance']}, "
            f"system_status={status['system']}) then clear {finalizer} — taking no action"
        )
        return False
    if state in (None, "terminated"):
        log(f"{name}: instance {instance_id} already gone ({reason}); clearing finalizer")
    else:
        log(
            f"{name}: terminating stuck pool={pool_name} node={node_name} instance={instance_id} "
            f"({reason}; ec2_state={state}, instance_status={status['instance']}, system_status={status['system']})"
        )
        if state != "shutting-down":
            ec2.terminate_instance(instance_id)
        if not wait_for_termination(
            ec2,
            instance_id,
            timeout_seconds=config["termination_wait_seconds"],
            poll_interval_seconds=config["poll_interval_seconds"],
        ):
            log(f"{name}: instance {instance_id} did not terminate before timeout; leaving finalizer intact")
            return True

    refreshed = kube.get_nodeclaim(name)
    if refreshed and finalizer in refreshed.get("metadata", {}).get("finalizers", []):
        remaining = [value for value in refreshed["metadata"]["finalizers"] if value != finalizer]
        kube.patch_nodeclaim_finalizers(
            name, remaining, refreshed["metadata"].get("resourceVersion")
        )
        log(f"{name}: removed {finalizer} after instance {instance_id} termination")

    if node_name:
        kube.delete_node(node_name)
        log(f"{name}: deleted dead Node object {node_name}")

    return False


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} /path/to/config.json", file=sys.stderr)
        return 2

    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        config = json.load(fh)

    kube = KubernetesApi()
    ec2 = Ec2Api(config["region"], PodIdentityCredentialsProvider())
    had_error = False

    nodeclaims = kube.list_nodeclaims()
    if not nodeclaims:
        log("no NodeClaims found")
        return 0

    for nodeclaim in nodeclaims:
        name = nodeclaim.get("metadata", {}).get("name", "<unknown>")
        try:
            had_error = process_nodeclaim(kube, ec2, config, nodeclaim) or had_error
        except KubernetesApiError as exc:
            if exc.status_code == 409:
                log(f"{name}: finalizer patch raced with another controller (409); will retry on the next run")
                continue
            had_error = True
            log(f"{name}: kubernetes api error: {exc}")
        except Exception as exc:  # noqa: BLE001
            had_error = True
            log(f"{name}: unexpected error: {exc}")

    return 1 if had_error else 0


if __name__ == "__main__":
    sys.exit(main())
