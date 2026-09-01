#!/usr/bin/env bash
# Tests for kubectl-distai_mcp, against stubs. No cluster, no AWS.
#
# The contract's promises are mostly about what happens when something is wrong: the cluster is
# unreachable, a Service is not an MCP, the endpoint answers HTTP but not MCP, a proxy is configured,
# the chart is older than the client. Those paths are the reason this file exists; the happy path is
# one test among many here.

_dm_bin() { printf '%s' "$SCRIPT_DIR/../bin/kubectl-distai_mcp"; }

# A kubectl that answers from a table given in SVCS: "name:port:path" per line, path empty for none.
# UNLABELED holds Services that exist in the namespace but carry no mcp-host label, which is what an
# older chart leaves behind. GET_RC/GET_ERR make the list fail the way a denied or expired call does.
_dm_stub_kubectl() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat >"$dir/bin/kubectl" <<STUB
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"config current-context"*) printf 'stub-ctx\n' ;;
  *"get svc"*)
    if [ -n "\${GET_RC:-}" ] && [ "\${GET_RC}" != "0" ]; then
      printf '%s\n' "\${GET_ERR:-error: forbidden}" >&2
      exit "\${GET_RC}"
    fi
    case "\$args" in
      *"-l app.kubernetes.io/component=mcp-host"*)
        printf '%s\n' "\${SVCS:-}" | while IFS=: read -r n p a; do
          [ -n "\$n" ] || continue
          case "\$args" in
            *jsonpath*port*) printf '%s %s %s\n' "\$n" "\${p:-8080}" "\$a" ;;
            *) printf '%s\n' "\$n" ;;
          esac
        done
        ;;
      *)
        printf '%s\n' "\${UNLABELED:-}" | while IFS=: read -r n p a; do
          [ -n "\$n" ] || continue
          printf '%s\n' "\$n"
        done
        ;;
    esac
    ;;
  *port-forward*)
    want=""
    for a in "\$@"; do case "\$a" in *:*[0-9]) want="\${a%%:*}" ;; esac; done
    [ -n "\$want" ] || want=54321
    if [ -n "\${PORT_BUSY:-}" ] && [ "\${PORT_BUSY}" = "\$want" ]; then
      printf 'Unable to listen on port %s: bind: address already in use\n' "\$want" >&2
      exit 1
    fi
    printf 'Forwarding from 127.0.0.1:%s -> %s\n' "\$want" "\${args##* }"
    printf '%s\n' "\$\$" >>"$dir/pids"
    printf '%s\n' "\$args" >>"$dir/specs"
    sleep 120 &
    wait
    ;;
  *) ;;
esac
STUB
  chmod +x "$dir/bin/kubectl"
}

# A curl that refuses unless the loopback exemption is passed, so the proxy defect cannot come back,
# and whose body is chosen by MODE: a real initialize result, a JSON-RPC error carried over HTTP 200,
# or a plain 200 from something that is not an MCP at all.
_dm_stub_curl() {
  local dir="$1"
  cat >"$dir/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *--noproxy*) ;;
  *) printf 'stub curl: no --noproxy, a configured http_proxy would break this\n' >&2; exit 5 ;;
esac
case "${MODE:-good}" in
  good) printf 'event: message\ndata: {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{}}}\n' ;;
  jsonrpcerror) printf 'event: message\ndata: {"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"bad request"}}\n' ;;
  plain) printf 'OK\n' ;;
  refused) exit 7 ;;
esac
STUB
  chmod +x "$dir/bin/curl"
}


# M6, M1: one MCP Service and one Service that is not an MCP, and a declared port that is not 8080.
test_distai_mcp_discovers_by_label_and_reads_the_declared_port() {
  local bin dir out fails=0
  bin="$(_dm_bin)"; [ -x "$bin" ] || return 2
  dir="$(mktemp -d)"
  _dm_stub_kubectl "$dir"
  _dm_stub_curl "$dir"
  out="$(env PATH="$dir/bin:$PATH" TMPDIR="$dir" \
    SVCS="analysis:9000:" UNLABELED="analysis:9000:
grafana:3000:" MODE=good "$bin" config 2>&1)" || {
    printf 'FAIL config failed: %s\n' "$out" >&2; fails=$((fails + 1)); }
  case "$out" in
    *'"analysis"'*) ;;
    *) printf 'FAIL the labelled Service is missing from the config: %s\n' "$out" >&2; fails=$((fails + 1)) ;;
  esac
  case "$out" in
    *grafana*) printf 'FAIL a Service without the label was treated as an MCP: %s\n' "$out" >&2; fails=$((fails + 1)) ;;
  esac
  # The remote port is the Service's, so the pair kubectl was asked to forward must name 9000.
  grep -q ':9000' "$dir/specs" 2>/dev/null || {
    printf 'FAIL the declared port 9000 was not forwarded (kubectl was asked: %s)\n' \
      "$(cat "$dir/specs" 2>/dev/null)" >&2; fails=$((fails + 1)); }
  env PATH="$dir/bin:$PATH" TMPDIR="$dir" SVCS="analysis:9000:" "$bin" down >/dev/null 2>&1
  rm -rf "$dir"
  [ "$fails" -eq 0 ] || return 1
}

# M1: the path comes from the Service annotation when it is set.
test_distai_mcp_takes_the_path_from_the_annotation() {
  local bin dir out fails=0
  bin="$(_dm_bin)"; [ -x "$bin" ] || return 2
  dir="$(mktemp -d)"
  _dm_stub_kubectl "$dir"
  _dm_stub_curl "$dir"
  out="$(env PATH="$dir/bin:$PATH" TMPDIR="$dir" \
    SVCS="weird:8080:/rpc" MODE=good "$bin" config 2>&1)"
  case "$out" in
    */rpc*) ;;
    *) printf 'FAIL the annotated path was ignored: %s\n' "$out" >&2; fails=$((fails + 1)) ;;
  esac
  env PATH="$dir/bin:$PATH" TMPDIR="$dir" SVCS="weird:8080:/rpc" "$bin" down >/dev/null 2>&1
  rm -rf "$dir"
  [ "$fails" -eq 0 ] || return 1
}

# M4: HTTP 200 is not the question. A JSON-RPC error and a non-MCP 200 must both be reported as not
# answering MCP, and must not be reported as a working endpoint.
test_distai_mcp_probe_reads_the_body_not_the_status() {
  local bin dir out fails=0 mode
  bin="$(_dm_bin)"; [ -x "$bin" ] || return 2
  dir="$(mktemp -d)"
  _dm_stub_kubectl "$dir"
  _dm_stub_curl "$dir"
  for mode in jsonrpcerror plain; do
    out="$(env PATH="$dir/bin:$PATH" TMPDIR="$dir" \
      SVCS="analysis:8080:" MODE="$mode" "$bin" up 2>&1)" && {
      printf 'FAIL up succeeded with MODE=%s: %s\n' "$mode" "$out" >&2; fails=$((fails + 1)); }
    # 文言ではなく、MCP として応答しないことが理由として挙がっているかを見る。
    case "$out" in
      *MCP*) ;;
      *) printf 'FAIL MODE=%s was not reported as an MCP problem: %s\n' "$mode" "$out" >&2; fails=$((fails + 1)) ;;
    esac
    env PATH="$dir/bin:$PATH" TMPDIR="$dir" SVCS="analysis:8080:" "$bin" down >/dev/null 2>&1
  done
  rm -rf "$dir"
  [ "$fails" -eq 0 ] || return 1
}

# M2: what to close is known locally. With the cluster gone, down still closes and status still shows.
test_distai_mcp_down_and_status_use_local_state() {
  local bin dir out fails=0 pid left=0
  bin="$(_dm_bin)"; [ -x "$bin" ] || return 2
  dir="$(mktemp -d)"
  _dm_stub_kubectl "$dir"
  _dm_stub_curl "$dir"
  : >"$dir/pids"
  env PATH="$dir/bin:$PATH" TMPDIR="$dir" SVCS="analysis:8080:" MODE=good "$bin" up >/dev/null 2>&1
  # The cluster is now unreachable: every list fails.
  out="$(env PATH="$dir/bin:$PATH" TMPDIR="$dir" GET_RC=1 \
    GET_ERR="Unable to connect to the server" MODE=good "$bin" status 2>&1)"
  case "$out" in
    *127.0.0.1*) ;;
    *) printf 'FAIL status hid an open tunnel when the cluster was unreachable: %s\n' "$out" >&2; fails=$((fails + 1)) ;;
  esac
  env PATH="$dir/bin:$PATH" TMPDIR="$dir" GET_RC=1 "$bin" down >/dev/null 2>&1
  while read -r pid; do
    [ -n "$pid" ] || continue
    # if, not &&: the harness runs each test under set -e, so a kill -0 that fails on an already dead
    # process would abort the test instead of counting zero.
    if kill -0 "$pid" 2>/dev/null; then left=$((left + 1)); fi
  done <"$dir/pids"
  [ "$left" = "0" ] || { printf 'FAIL down left %s forward(s) running with the cluster unreachable\n' "$left" >&2; fails=$((fails + 1)); }
  # Addressing a different context is a different record, and down must not claim to have closed the
  # tunnels of the one it is not looking at.
  env PATH="$dir/bin:$PATH" TMPDIR="$dir" MODE=good "$bin" up >/dev/null 2>&1 || true
  out="$(env PATH="$dir/bin:$PATH" TMPDIR="$dir" KUBE_CONTEXT=other-ctx "$bin" down 2>&1)"
  case "$out" in
    *"nothing was open"*) ;;
    *) printf 'FAIL down claimed to close another context'"'"'s tunnels: %s\n' "$out" >&2; fails=$((fails + 1)) ;;
  esac
  # The top-level dispatch is not a function, so a `local` there is a runtime error that bash prints and
  # walks past; the message stays correct while the script is broken.
  case "$out" in
    *"can only be used in a function"*|*"line "*": local:"*)
      printf 'FAIL down hit a shell error: %s\n' "$out" >&2; fails=$((fails + 1)) ;;
  esac
  env PATH="$dir/bin:$PATH" TMPDIR="$dir" "$bin" down >/dev/null 2>&1 || true
  rm -rf "$dir"
  [ "$fails" -eq 0 ] || return 1
}

# M3: a denied or expired list is not "no MCP servers here", and the prescription must not be "install
# the platform" for a permission problem.
test_distai_mcp_reports_a_denied_list_as_a_permission_problem() {
  local bin dir out fails=0
  bin="$(_dm_bin)"; [ -x "$bin" ] || return 2
  dir="$(mktemp -d)"
  _dm_stub_kubectl "$dir"
  _dm_stub_curl "$dir"
  out="$(env PATH="$dir/bin:$PATH" TMPDIR="$dir" GET_RC=1 \
    GET_ERR='Error from server (Forbidden): services is forbidden' "$bin" up 2>&1)" && {
    printf 'FAIL up succeeded with a forbidden list\n' >&2; fails=$((fails + 1)); }
  case "$out" in
    *Forbidden*) ;;
    *) printf "FAIL kubectl's own error was swallowed: %s\n" "$out" >&2; fails=$((fails + 1)) ;;
  esac
  case "$out" in
    *Install*|*install*) printf 'FAIL a failed list was prescribed as a missing install: %s\n' "$out" >&2; fails=$((fails + 1)) ;;
  esac
  # One diagnosis, not two. A die inside a command substitution ends only that subshell, so a second,
  # wrong explanation used to follow the right one and have the last word.
  [ "$(printf '%s\n' "$out" | grep -c '^error:')" = "1" ] ||
    { printf 'FAIL more than one error was reported: %s\n' "$out" >&2; fails=$((fails + 1)); }
  rm -rf "$dir"
  [ "$fails" -eq 0 ] || return 1
}

# M8: zero labelled Services with unlabelled ones present is an old chart, not a missing platform.
test_distai_mcp_names_an_old_chart_when_the_label_is_absent() {
  local bin dir out fails=0
  bin="$(_dm_bin)"; [ -x "$bin" ] || return 2
  dir="$(mktemp -d)"
  _dm_stub_kubectl "$dir"
  _dm_stub_curl "$dir"
  out="$(env PATH="$dir/bin:$PATH" TMPDIR="$dir" \
    SVCS="" UNLABELED="analysis:8080:
knowledge:8080:" "$bin" up 2>&1)" && {
    printf 'FAIL up succeeded with no labelled Service\n' >&2; fails=$((fails + 1)); }
  case "$out" in
    *chart*|*ラベル*|*label*) ;;
    *) printf 'FAIL an older chart was not offered as the reason: %s\n' "$out" >&2; fails=$((fails + 1)) ;;
  esac
  rm -rf "$dir"
  [ "$fails" -eq 0 ] || return 1
}

# The contract says an occupied --local-port fails rather than moving, because a caller that asked for
# a specific port asked for it on purpose.
test_distai_mcp_local_port_does_not_move_silently() {
  local bin dir out fails=0
  bin="$(_dm_bin)"; [ -x "$bin" ] || return 2
  dir="$(mktemp -d)"
  _dm_stub_kubectl "$dir"
  _dm_stub_curl "$dir"
  out="$(env PATH="$dir/bin:$PATH" TMPDIR="$dir" \
    SVCS="analysis:8080:" PORT_BUSY=18000 MODE=good "$bin" up --local-port analysis=18000 2>&1)" && {
    printf 'FAIL up succeeded although the requested port was busy: %s\n' "$out" >&2; fails=$((fails + 1)); }
  case "$out" in
    *18000*) ;;
    *) printf 'FAIL the failure did not name the requested port: %s\n' "$out" >&2; fails=$((fails + 1)) ;;
  esac
  env PATH="$dir/bin:$PATH" TMPDIR="$dir" SVCS="analysis:8080:" "$bin" down >/dev/null 2>&1
  rm -rf "$dir"
  [ "$fails" -eq 0 ] || return 1
}

# exec hands its exit code back and exports the config under the generic names.
test_distai_mcp_exec_exports_generic_names_and_passes_the_exit_code() {
  local bin dir out rc fails=0
  bin="$(_dm_bin)"; [ -x "$bin" ] || return 2
  dir="$(mktemp -d)"
  _dm_stub_kubectl "$dir"
  _dm_stub_curl "$dir"
  : >"$dir/pids"
  out="$(env PATH="$dir/bin:$PATH" TMPDIR="$dir" SVCS="analysis:8080:" MODE=good \
    "$bin" exec -- sh -c 'printf "%s\n" "$DISTAI_MCP_CONFIG"; printf "url=%s\n" "$DISTAI_MCP_ANALYSIS_URL"; exit 7' 2>&1)"
  rc=$?
  [ "$rc" = "7" ] || { printf 'FAIL the wrapped command did not own the exit code, got %s\n' "$rc" >&2; fails=$((fails + 1)); }
  case "$out" in
    *'"mcpServers"'*'"analysis"'*) ;;
    *) printf 'FAIL DISTAI_MCP_CONFIG was not exported: %s\n' "$out" >&2; fails=$((fails + 1)) ;;
  esac
  case "$out" in
    *"url=http://127.0.0.1:"*) ;;
    *) printf 'FAIL the per-server URL was not exported: %s\n' "$out" >&2; fails=$((fails + 1)) ;;
  esac
  case "$out" in
    *accelprof*) printf 'FAIL the generic plugin exported an accelprof name: %s\n' "$out" >&2; fails=$((fails + 1)) ;;
  esac
  # A leaked forward keeps working, so nobody notices it until a later run finds the port taken. That
  # is the one promise here a reader would never see broken.
  local pid left=0
  while read -r pid; do
    [ -n "$pid" ] || continue
    # if, not &&: the harness runs each test under set -e, so a kill -0 that fails on an already dead
    # process would abort the test instead of counting zero.
    if kill -0 "$pid" 2>/dev/null; then left=$((left + 1)); fi
  done <"$dir/pids"
  [ "$left" = "0" ] || { printf 'FAIL exec left %s forward(s) running after it returned\n' "$left" >&2; fails=$((fails + 1)); }
  [ -z "$(ls -A "$dir/distai-mcp" 2>/dev/null)" ] ||
    { printf 'FAIL exec left state behind in %s\n' "$dir/distai-mcp" >&2; fails=$((fails + 1)); }
  rm -rf "$dir"
  [ "$fails" -eq 0 ] || return 1
}

# The chart is the other half of the discovery contract: without the label on the Service, the client
# cannot find anything, so the two must change together.
# Vendor the chart's subchart (s3files-lib) so `helm template` can render it. charts/*/charts/ is
# gitignored, so on a fresh checkout the dependency is absent and the render fails with helm's
# "missing in charts/ directory" rather than anything about this test. Guarded to run once per
# process, because `helm dependency build` rewrites charts/*.tgz and Chart.lock and concurrent runs
# would race on those files. The dependency is a local path, so this needs no network. `update` is
# the fallback for a Chart.lock digest that no longer matches Chart.yaml.
_mcp_ensure_deps() {
  [ -n "${_MCP_DEPS_DONE:-}" ] && return 0
  local chart="$1" out
  if ! out="$(helm dependency build "$chart" 2>&1)"; then
    out="$(helm dependency update "$chart" 2>&1)" || {
      printf 'chart dependency vendoring failed: %s\n' "$out" >&2
      return 1
    }
  fi
  _MCP_DEPS_DONE=1
}

test_mcp_host_chart_labels_the_service() {
  local chart fails=0
  chart="$SCRIPT_DIR/../charts/mcp-host"
  [ -d "$chart" ] || return 2
  command -v helm >/dev/null || return 2
  _mcp_ensure_deps "$chart" || return 1
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
