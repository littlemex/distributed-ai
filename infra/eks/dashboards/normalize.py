#!/usr/bin/env python3
"""Normalize a Grafana.com dashboard JSON for import via the kube-prometheus-stack
Grafana sidecar.

A dashboard exported from grafana.com carries an `__inputs` block that turns its
datasource into an import-time prompt (`${DS_PROMETHEUS}`), plus a `__requires`
block. The sidecar imports ConfigMap-backed dashboards non-interactively, so
those inputs are never answered and every panel ends up pointing at an unresolved
datasource. This script strips the import scaffolding and pins every datasource
reference to the kube-prometheus-stack Prometheus, whose uid is "prometheus".

Usage:
    python3 normalize.py < raw-from-grafana-com.json > dashboards/<name>.json

The output is deterministic (sorted keys off, stable indent) so re-running it on
the same input yields byte-identical JSON, which keeps Terraform plan diffs
meaningful. See README.md for the source URL and revision of each vendored file.
"""
import json
import sys

# The kube-prometheus-stack Grafana provisions its Prometheus with this uid
# (grafana.sidecar.datasources default). Every datasource reference is pinned
# here so the dashboard resolves without any import-time prompt.
PROM_UID = "prometheus"


def pin_datasource(node):
    """Recursively rewrite datasource references to the pinned Prometheus uid.

    Handles the three shapes grafana.com JSON uses:
      - the "${DS_PROMETHEUS}" input placeholder (string or {"uid": "..."} form)
      - a bare uid string on a panel/target
      - a datasource-typed template variable, whose `current` is pinned so the
        variable defaults to the real datasource instead of an empty selection.
    """
    if isinstance(node, dict):
        # A datasource reference object: {"type": "prometheus", "uid": "..."}.
        if "uid" in node and node.get("type") in (None, "prometheus", "datasource"):
            uid = node["uid"]
            if isinstance(uid, str) and (uid.startswith("${") or uid == "" or uid.startswith("DS_")):
                node["uid"] = PROM_UID
        for k, v in node.items():
            # A datasource-typed template variable: pin its current selection.
            if k == "type" and v == "datasource":
                node.setdefault("current", {})
                node["current"] = {"text": "Prometheus", "value": PROM_UID, "selected": True}
            node[k] = pin_datasource(v)
        return node
    if isinstance(node, list):
        return [pin_datasource(v) for v in node]
    if isinstance(node, str) and (node.startswith("${DS_") or node == "${DS_PROMETHEUS}"):
        return PROM_UID
    return node


def main():
    d = json.load(sys.stdin)
    # Drop the import scaffolding; the sidecar imports non-interactively.
    d.pop("__inputs", None)
    d.pop("__requires", None)
    # A concrete id/uid from the export would collide across clusters; let Grafana
    # assign one on import. The gnetId (grafana.com origin) is kept for provenance.
    d.pop("id", None)
    d = pin_datasource(d)
    json.dump(d, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
