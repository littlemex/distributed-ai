#!/usr/bin/env bash
# Tests for how the profiling client resolves "the run I just submitted", against a stub kubectl. No
# cluster, no AWS.
#
# This exists because the convenience is the dangerous part. Reading the newest run out of the
# cluster saves the reader from copying a workload id by hand, but a wrong answer is worse than no
# answer: they would read the status of somebody else's run and conclude something about their own.
# The paths below are the ones where that can happen — nothing recorded yet, nothing at all, and two
# submissions that landed in the same second.

_ac_client() { printf '%s' "$SCRIPT_DIR/../bin/kubectl-accelprof"; }

# A kubectl that answers the two queries the client makes, from a table given as JOBS: one
# "timestamp workload-id run-id conditions" row per line. Everything else answers empty, which is
# what a real kubectl does for a namespace with nothing in it.
_ac_stub() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat >"$dir/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# The client asks for a go-template listing (timestamp and workload id), then for one job by label,
# then for that job's run-id annotation and conditions.
args="$*"
rows="${JOBS:-}"
case "$args" in
  *go-template*)
    printf '%s\n' "$rows" | awk 'NF >= 2 { print $1, $2 }'
    ;;
  *"-l accelprof.io/workload-id="*)
    want="${args##*-l accelprof.io/workload-id=}"; want="${want%% *}"
    printf '%s\n' "$rows" | awk -v w="$want" 'NF >= 2 && $2 == w { print "profile-" $2; exit }'
    ;;
  *"jsonpath={.metadata.annotations.accelprof\.io/run-id}"*)
    job="${args#*get job }"; job="${job%% *}"; want="${job#profile-}"
    printf '%s\n' "$rows" | awk -v w="$want" 'NF >= 3 && $2 == w && $3 != "-" { print $3; exit }'
    ;;
  *conditions*)
    job="${args#*get job }"; job="${job%% *}"; want="${job#profile-}"
    printf '%s\n' "$rows" | awk -v w="$want" 'NF >= 4 && $2 == w { print $4; exit }'
    ;;
  *configmap*) ;;
  *) ;;
esac
STUB
  chmod +x "$dir/bin/kubectl"
}

# Runs the client with the stub in front of PATH and reports "<rc> <output with newlines as |>".
_ac_run() {
  local jobs="$1"; shift
  local dir out rc
  dir="$(mktemp -d)"
  _ac_stub "$dir"
  out="$(JOBS="$jobs" PATH="$dir/bin:$PATH" KUBE_CONTEXT="" "$(_ac_client)" "$@" 2>&1)" && rc=0 || rc=$?
  rm -rf "$dir"
  printf '%d %s' "$rc" "$(printf '%s' "$out" | tr '\n' '|')"
}

test_accelprof_client_resolves_newest_run() {
  [ -x "$(_ac_client)" ] || return 2
  local fails=0 got

  # The ordinary case: several runs, the newest one is used and named in the output.
  got="$(_ac_run '2026-08-27T05:00:00Z wl-a 111 Complete
2026-08-27T06:00:00Z wl-b 222 Complete' get -n team-a)"
  case "$got" in
    0*"newest run in team-a: wl-b"*"run_id:      222"*) ;;
    *) printf 'FAIL newest run: %s\n' "$got" >&2; fails=$((fails + 1)) ;;
  esac

  # Machine-readable modes carry one value, for filling a shell variable.
  got="$(_ac_run '2026-08-27T06:00:00Z wl-b 222 Complete' get -n team-a -o id)"
  [ "$got" = "0 wl-b" ] || { printf 'FAIL -o id: %s\n' "$got" >&2; fails=$((fails + 1)); }
  got="$(_ac_run '2026-08-27T06:00:00Z wl-b 222 Complete' get -n team-a -o run-id)"
  [ "$got" = "0 222" ] || { printf 'FAIL -o run-id: %s\n' "$got" >&2; fails=$((fails + 1)); }

  # A run that has not been recorded yet must not answer with an empty run id as if it had one.
  got="$(_ac_run '2026-08-27T06:00:00Z wl-b - Running' get -n team-a -o run-id)"
  case "$got" in
    0*) printf 'FAIL unrecorded run answered: %s\n' "$got" >&2; fails=$((fails + 1)) ;;
    *"no run id yet"*) ;;
    *) printf 'FAIL unrecorded run message: %s\n' "$got" >&2; fails=$((fails + 1)) ;;
  esac

  # Nothing at all: a message that says where the recording still is, not a silent death. This failed
  # exactly once, when an empty grep under pipefail killed the script before it could speak.
  got="$(_ac_run '' get -n team-a)"
  case "$got" in
    1*"no runs in team-a"*"runs"*) ;;
    *) printf 'FAIL empty namespace: %s\n' "$got" >&2; fails=$((fails + 1)) ;;
  esac

  # Two runs in the same second: there is no newest, so it refuses and names both.
  got="$(_ac_run '2026-08-27T06:00:00Z wl-x 111 Complete
2026-08-27T06:00:00Z wl-y 222 Complete' get -n team-a)"
  case "$got" in
    1*"same second"*wl-x*wl-y*) ;;
    *) printf 'FAIL same-second tie: %s\n' "$got" >&2; fails=$((fails + 1)) ;;
  esac

  # An explicit id is still honoured, and is not overridden by whatever is newest.
  got="$(_ac_run '2026-08-27T05:00:00Z wl-a 111 Complete
2026-08-27T06:00:00Z wl-b 222 Complete' get wl-a -n team-a)"
  case "$got" in
    0*"workload wl-a in team-a"*"run_id:      111"*) ;;
    *) printf 'FAIL explicit id: %s\n' "$got" >&2; fails=$((fails + 1)) ;;
  esac

  [ "$fails" -eq 0 ] || { printf '%d client case(s) failed\n' "$fails" >&2; return 1; }
}

# The hints the client prints are commands the reader will paste. They have to be the plugin form
# (kubectl accelprof ...), not the file name it is installed under.
test_accelprof_client_hints_are_plugin_form() {
  local client
  client="$(_ac_client)"
  [ -f "$client" ] || return 2
  local stray
  stray="$(grep -nE "printf '.*(run id|list what is left|get )" "$client" | grep '\${self}' || true)"
  [ -z "$stray" ] || {
    printf 'these hints name the file instead of the plugin:\n%s\n' "$stray" >&2
    return 1
  }
}
