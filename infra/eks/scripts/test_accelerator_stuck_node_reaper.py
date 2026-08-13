#!/usr/bin/env python3

from __future__ import annotations

import datetime as dt
import json
from pathlib import Path
import sys
import unittest
from unittest import mock
import xml.etree.ElementTree as ET


sys.path.insert(0, str(Path(__file__).resolve().parent))

import accelerator_stuck_node_reaper as reaper  # noqa: E402

from accelerator_stuck_node_reaper import (  # noqa: E402
    AwsApiError,
    Ec2Api,
    KubernetesApi,
    KubernetesApiError,
    clear_finalizer_if_safe,
    node_is_reapable,
    nodeclaim_is_stuck,
    parse_duration,
    parse_instance_id,
    strip_namespaces,
)


def rfc3339_seconds_ago(seconds: int) -> str:
    return (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")


class ParseDurationTests(unittest.TestCase):
    def test_supports_seconds_minutes_and_hours(self) -> None:
        self.assertEqual(parse_duration("15s"), 15)
        self.assertEqual(parse_duration("20m"), 1200)
        self.assertEqual(parse_duration("2h"), 7200)

    def test_rejects_invalid_input(self) -> None:
        for value in ("20", "5d"):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    parse_duration(value)


class ParseInstanceIdTests(unittest.TestCase):
    def test_extracts_instance_id_from_provider_id(self) -> None:
        self.assertEqual(
            parse_instance_id("aws:///us-east-2a/i-0123456789abcdef0"),
            "i-0123456789abcdef0",
        )

    def test_returns_none_for_missing_or_empty_provider_id(self) -> None:
        self.assertIsNone(parse_instance_id(None))
        self.assertIsNone(parse_instance_id(""))
        self.assertIsNone(parse_instance_id("aws:///"))


class StripNamespacesTests(unittest.TestCase):
    def test_strips_default_and_prefixed_namespaces(self) -> None:
        root = ET.fromstring(
            """
            <root xmlns="urn:root" xmlns:x="urn:child">
              <child>
                <x:item>value</x:item>
              </child>
            </root>
            """
        )

        stripped = strip_namespaces(root)

        self.assertEqual(stripped.tag, "root")
        self.assertEqual(stripped.find("./child/item").text, "value")


class DescribeInstanceStateTests(unittest.TestCase):
    def test_returns_none_only_for_confirmed_missing_instance(self) -> None:
        ec2 = object.__new__(Ec2Api)

        def raise_not_found(action: str, params: dict[str, str]) -> ET.Element:
            raise AwsApiError("InvalidInstanceID.NotFound", "missing")

        ec2._request = raise_not_found  # type: ignore[attr-defined]

        self.assertIsNone(ec2.describe_instance_state("i-0123456789abcdef0"))

    def test_raises_on_200_without_instance_state(self) -> None:
        ec2 = object.__new__(Ec2Api)
        ec2._request = lambda action, params: ET.fromstring("<DescribeInstancesResponse/>")  # type: ignore[attr-defined]

        with self.assertRaises(AwsApiError) as ctx:
            ec2.describe_instance_state("i-0123456789abcdef0")

        self.assertEqual(ctx.exception.code, "UnparseableInstanceState")


class PatchNodeclaimFinalizersTests(unittest.TestCase):
    def test_includes_resource_version_in_patch_body(self) -> None:
        kube = object.__new__(KubernetesApi)
        captured: dict[str, str] = {}

        def fake_request(method: str, path: str, body: str | None = None, content_type: str = "application/json") -> None:
            captured["method"] = method
            captured["path"] = path
            captured["body"] = body or ""
            captured["content_type"] = content_type

        kube._request = fake_request  # type: ignore[attr-defined]

        kube.patch_nodeclaim_finalizers("claim-1", ["other.finalizer"], "12345")

        payload = json.loads(captured["body"])
        self.assertEqual(captured["method"], "PATCH")
        self.assertEqual(captured["content_type"], "application/merge-patch+json")
        self.assertEqual(payload["metadata"]["finalizers"], ["other.finalizer"])
        self.assertEqual(payload["metadata"]["resourceVersion"], "12345")


class ClearFinalizerIfSafeTests(unittest.TestCase):
    @staticmethod
    def make_kube() -> mock.Mock:
        kube = mock.Mock()
        kube.get_nodeclaim.return_value = {
            "metadata": {
                "finalizers": ["karpenter.sh/termination", "other.finalizer"],
                "resourceVersion": "42",
            }
        }
        return kube

    def test_dry_run_does_not_patch_or_delete(self) -> None:
        kube = self.make_kube()
        ec2 = mock.Mock()
        ec2.describe_instance_state.return_value = None

        with mock.patch.object(reaper, "log"):
            clear_finalizer_if_safe(
                kube,
                ec2,
                "claim-1",
                "node-1",
                "aws:///us-west-2a/i-0123456789abcdef0",
                "karpenter.sh/termination",
                dry_run=True,
            )

        kube.get_nodeclaim.assert_not_called()
        kube.patch_nodeclaim_finalizers.assert_not_called()
        kube.delete_node.assert_not_called()

    def test_clears_finalizer_and_deletes_node_when_instance_is_gone(self) -> None:
        kube = self.make_kube()
        ec2 = mock.Mock()
        ec2.describe_instance_state.return_value = None

        with mock.patch.object(reaper, "log"):
            clear_finalizer_if_safe(
                kube,
                ec2,
                "claim-1",
                "node-1",
                "aws:///us-west-2a/i-0123456789abcdef0",
                "karpenter.sh/termination",
                dry_run=False,
            )

        kube.patch_nodeclaim_finalizers.assert_called_once_with(
            "claim-1",
            ["other.finalizer"],
            "42",
        )
        kube.delete_node.assert_called_once_with("node-1")


class NodeclaimIsStuckTests(unittest.TestCase):
    def test_requires_deletion_timestamp_and_matching_finalizer(self) -> None:
        nodeclaim = {
            "metadata": {
                "deletionTimestamp": "2026-08-12T00:00:00Z",
                "finalizers": ["karpenter.sh/termination"],
            }
        }
        self.assertTrue(nodeclaim_is_stuck(nodeclaim, "karpenter.sh/termination"))
        self.assertFalse(nodeclaim_is_stuck({"metadata": {"finalizers": ["karpenter.sh/termination"]}}, "karpenter.sh/termination"))
        self.assertFalse(nodeclaim_is_stuck(nodeclaim, "other.finalizer/example"))


class NodeIsReapableTests(unittest.TestCase):
    @staticmethod
    def make_node(status: str, reason: str, age_seconds: int) -> dict:
        return {
            "status": {
                "conditions": [{
                    "type": "Ready",
                    "status": status,
                    "reason": reason,
                    "lastTransitionTime": rfc3339_seconds_ago(age_seconds),
                }]
            }
        }

    def test_reapable_when_kubelet_dead_beyond_threshold(self) -> None:
        reapable, reason = node_is_reapable(
            self.make_node(status="Unknown", reason="NodeStatusUnknown", age_seconds=180),
            threshold_seconds=60,
        )

        self.assertTrue(reapable)
        self.assertIn("NodeStatusUnknown", reason)

    def test_not_reapable_when_ready_true(self) -> None:
        reapable, reason = node_is_reapable(
            self.make_node(status="True", reason="KubeletReady", age_seconds=180),
            threshold_seconds=60,
        )

        self.assertFalse(reapable)
        self.assertEqual(reason, "Ready=True")

    def test_not_reapable_for_unproven_notready_reason(self) -> None:
        reapable, reason = node_is_reapable(
            self.make_node(status="False", reason="KubeletNotReady", age_seconds=180),
            threshold_seconds=60,
        )

        self.assertFalse(reapable)
        self.assertIn("not a proven kubelet-dead state", reason)

    def test_not_reapable_before_threshold(self) -> None:
        reapable, reason = node_is_reapable(
            self.make_node(status="Unknown", reason="NodeStatusUnknown", age_seconds=30),
            threshold_seconds=60,
        )

        self.assertFalse(reapable)
        self.assertIn("< threshold 60s", reason)


class MainTests(unittest.TestCase):
    def test_conflict_does_not_fail_the_run(self) -> None:
        kube = mock.Mock()
        kube.list_nodeclaims.return_value = [{"metadata": {"name": "claim-1"}}]
        config = {
            "region": "us-west-2",
            "pools": {},
            "karpenter_termination_finalizer": "karpenter.sh/termination",
            "termination_wait_seconds": 60,
            "poll_interval_seconds": 5,
        }

        with (
            mock.patch.object(reaper, "KubernetesApi", return_value=kube),
            mock.patch.object(reaper, "PodIdentityCredentialsProvider", return_value=object()),
            mock.patch.object(reaper, "Ec2Api", return_value=object()),
            mock.patch.object(reaper, "process_nodeclaim", side_effect=KubernetesApiError(409, "conflict")),
            mock.patch.object(reaper, "log") as log_mock,
            mock.patch("builtins.open", mock.mock_open(read_data=json.dumps(config))),
            mock.patch.object(reaper.sys, "argv", ["reaper.py", "/tmp/config.json"]),
        ):
            self.assertEqual(reaper.main(), 0)

        log_mock.assert_any_call(
            "claim-1: finalizer patch raced with another controller (409); will retry on the next run"
        )


if __name__ == "__main__":
    unittest.main()
