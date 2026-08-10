# Grafana dashboards

JSON dashboards shipped as sidecar-discovered ConfigMaps by
[`../observability.tf`](../observability.tf) (`kubectl_manifest.grafana_dashboard`,
one per entry in the `local.grafana_dashboards` map). The Grafana sidecar in the
kube-prometheus-stack release picks up any ConfigMap labeled `grafana_dashboard=1`
and files it under the folder named in the `grafana_folder` annotation.

Each `<name>.json` here maps 1:1 to a map key: the ConfigMap is
`grafana-dashboard-<name>`, its data key is `<name>.json`, and the source file is
`dashboards/<name>.json`.

## Files

| File | Origin | Folder | Notes |
|---|---|---|---|
| `gpu-tenant.json` | self-authored | GPU | Per-tenant GPU view. Reads the `tenant` label written by the self-managed DCGM ServiceMonitor. SM Clock panel unit is `hertz` with a `* 1e6` scale (DCGM reports MHz). |
| `node-exporter-full.json` | [grafana.com id 1860](https://grafana.com/grafana/dashboards/1860-node-exporter-full/) | Nodes | Node CPU/mem/disk/network from the kps node-exporter. |
| `dcgm-exporter.json` | [grafana.com id 12239](https://grafana.com/grafana/dashboards/12239-nvidia-dcgm-exporter-dashboard/) | GPU | GPU util/mem/temp/power from the GPU Operator dcgm-exporter. |

EFA and FSx dashboards are intentionally **not** vendored: no exporter emits those
metrics on this cluster yet, so their panels would render empty.

## Updating a community dashboard (1860, 12239)

The community JSON must be normalized before it can be imported non-interactively
by the sidecar — otherwise its `${DS_PROMETHEUS}` import prompt is never answered
and every panel points at an unresolved datasource. `normalize.py` strips the
import scaffolding (`__inputs`, `__requires`, `id`) and pins every datasource
reference to the kps Prometheus (uid `prometheus`).

```bash
# Download the desired revision from grafana.com, then:
python3 normalize.py < raw-1860.json  > node-exporter-full.json
python3 normalize.py < raw-12239.json > dcgm-exporter.json
```

The transform is deterministic, so re-running it yields byte-identical output and
Terraform `plan` diffs stay meaningful. Pin datasources through this script rather
than by hand so a fourth dashboard can't drift into a different normalization
style. `gpu-tenant.json` is hand-authored and already uses `uid: "prometheus"`
directly, so it does not go through `normalize.py`.
