#!/usr/bin/env bash
# Tests for the mcp-host chart contract.

# The chart is the other half of the discovery contract: without the label on the Service, the client
# cannot find anything, so the two must change together.
test_mcp_host_chart_labels_the_service() {
  local chart fails=0
  chart="$SCRIPT_DIR/../charts/mcp-host"
  [ -d "$chart" ] || return 2
  command -v helm >/dev/null || return 2
  local dir rendered
  dir="$(mktemp -d)"
  rendered="$dir/rendered.yaml"
  helm template mcp "$chart" --set-json 'mcps=[{"name":"analysis","transport":"http","image":{"repository":"r","tag":"t"},"command":["x"]},{"name":"weird","transport":"http","image":{"repository":"r","tag":"t"},"command":["x"],"port":9000,"path":"/rpc"}]' >"$rendered" 2>"$dir/err" || {
    printf 'FAIL helm template failed: %s\n' "$(tail -3 "$dir/err")" >&2; rm -rf "$dir"; return 1; }
  python3 -c 'import yaml' 2>/dev/null || { rm -rf "$dir"; return 2; }
  python3 - "$rendered" <<'PY' || fails=$((fails + 1))
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1]).read()) if isinstance(d, dict)]
svcs = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "Service"}
bad = []
for name in ("analysis", "weird"):
    s = svcs.get(name)
    if not s:
        bad.append("Service %s was not rendered" % name); continue
    if (s["metadata"].get("labels") or {}).get("app.kubernetes.io/component") != "mcp-host":
        bad.append("Service %s lacks app.kubernetes.io/component=mcp-host" % name)
if svcs.get("weird", {}).get("spec", {}).get("ports", [{}])[0].get("port") != 9000:
    bad.append("the declared port of weird is not 9000")
ann = (svcs.get("weird", {}).get("metadata", {}).get("annotations") or {})
if ann.get("mcp-host.distai.dev/path") != "/rpc":
    bad.append("weird lacks the path annotation")
if (svcs.get("analysis", {}).get("metadata", {}).get("annotations") or {}).get("mcp-host.distai.dev/path"):
    bad.append("analysis got a path annotation although the entry set no path")
for b in bad:
    print("FAIL " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
  rm -rf "$dir"
  [ "$fails" -eq 0 ] || return 1
}
