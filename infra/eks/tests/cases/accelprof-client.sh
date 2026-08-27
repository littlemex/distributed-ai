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

# The chip a run is filed under has to be the one the reader asked for. It was hardwired to gpu, so a
# CPU run came back labelled gpu and the reader could not tell whether the platform had understood
# what they submitted. It is also the key that alias-based resolution uses, so a wrong value hides a
# run from the search that is meant to find it.
test_accelprof_client_chip_follows_the_request() {
  local client
  client="$(_ac_client)"
  [ -x "$client" ] || return 2
  local fails=0
  render() {
    ACCELPROF_PLATFORM_IMAGE="image.example/accelprof@sha256:0" KUBE_CONTEXT="" "$client" run \
      --alias t-s --namespace ns --image image.example/w:t --dry-run "$@" -- true |
      # Two spellings have to be read: the template's inline mapping, and the re-serialised block form
      # the client emits once it has to inject device resources.
      grep -A1 ACCELPROF_CHIP | tr -d '",{}' | grep -o 'value: *[a-z]*' | head -1 | awk '{ print $2 }'
  }
  local got
  got="$(render)"
  [ "$got" = "cpu" ] || { printf 'FAIL no device: chip=%s\n' "$got" >&2; fails=$((fails + 1)); }
  got="$(render --gpu 1)"
  [ "$got" = "gpu" ] || { printf 'FAIL --gpu: chip=%s\n' "$got" >&2; fails=$((fails + 1)); }
  got="$(render --neuron 2)"
  [ "$got" = "neuron" ] || { printf 'FAIL --neuron: chip=%s\n' "$got" >&2; fails=$((fails + 1)); }
  got="$(render --profile neuron)"
  [ "$got" = "neuron" ] || { printf 'FAIL --profile neuron: chip=%s\n' "$got" >&2; fails=$((fails + 1)); }
  got="$(render --profile none)"
  [ "$got" = "cpu" ] || { printf 'FAIL --profile none: chip=%s\n' "$got" >&2; fails=$((fails + 1)); }
  [ "$fails" -eq 0 ] || return 1
}

# --wait exists to hand back the run id, so it has to wait for the id and not for the Job. The
# recorder writes the id onto the Job as its last act, so a wait that stops at Complete reports "not
# recorded yet" — which is what the flag was supposed to save the reader from.
test_accelprof_client_wait_waits_for_the_recording() {
  local client
  client="$(_ac_client)"
  [ -x "$client" ] || return 2
  local dir out
  dir="$(mktemp -d)"
  mkdir -p "$dir/bin"
  # A kubectl whose Job is Complete from the first look but only grows the run-id annotation on the
  # third, which is the ordering the real recorder produces.
  cat >"$dir/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
args="$*"
state="${STATE_FILE:?}"
case "$args" in
  *configmap*) printf 'image.example/accelprof@sha256:aaa\n' ;;
  *"apply -f"*) cat >/dev/null; printf 'job.batch/x created\n' ;;
  *"config view"*) printf 'ns\n' ;;
  *run-id*)
    n=$(( $(cat "$state" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" >"$state"
    [ "$n" -lt 3 ] || printf 'RUNID-42\n'
    ;;
  *conditions*) printf 'Complete \n' ;;
  *"-l accelprof.io/workload-id="*) printf 'profile-x\n' ;;
esac
STUB
  chmod +x "$dir/bin/kubectl"
  out="$(STATE_FILE="$dir/n" ACCELPROF_PLATFORM_IMAGE="image.example/accelprof@sha256:aaa" \
    PATH="$dir/bin:$PATH" KUBE_CONTEXT="" "$client" run --alias t-s --namespace ns \
    --image image.example/w:t --wait -- true 2>&1)"
  rm -rf "$dir"
  case "$out" in
    *"RUNID-42"*) ;;
    *) printf 'FAIL --wait returned before the recording existed: %s\n' "$(printf '%s' "$out" | tr '\n' '|')" >&2
       return 1 ;;
  esac
}

# --wait that gives up must not look like success. It used to fall through to the ordinary report,
# printing "not recorded yet" and exiting zero, which tells a script the recording exists.
test_accelprof_client_wait_fails_when_nothing_is_recorded() {
  local client
  client="$(_ac_client)"
  [ -x "$client" ] || return 2
  local dir out rc
  dir="$(mktemp -d)"
  mkdir -p "$dir/bin"
  # A Job that completes and a recorder that never writes an id.
  cat >"$dir/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *configmap*) printf 'image.example/accelprof@sha256:aaa\n' ;;
  *"apply -f"*) cat >/dev/null; printf 'job.batch/x created\n' ;;
  *"config view"*) printf 'ns\n' ;;
  *run-id*) ;;
  *conditions*) printf 'Complete \n' ;;
  *"-l accelprof.io/workload-id="*) printf 'profile-x\n' ;;
esac
STUB
  chmod +x "$dir/bin/kubectl"
  out="$(WAIT_RECORDER_GRACE_SECONDS=1 ACCELPROF_PLATFORM_IMAGE="image.example/accelprof@sha256:aaa" \
    PATH="$dir/bin:$PATH" KUBE_CONTEXT="" "$client" run --alias t-s --namespace ns \
    --image image.example/w:t --wait -- true 2>&1)" && rc=0 || rc=$?
  rm -rf "$dir"
  [ "$rc" -ne 0 ] || { printf 'FAIL --wait exited 0 with nothing recorded: %s\n' "$(printf '%s' "$out" | tr '\n' '|')" >&2; return 1; }
  case "$out" in
    *"did not appear"*) ;;
    *) printf 'FAIL --wait timeout said nothing useful: %s\n' "$(printf '%s' "$out" | tr '\n' '|')" >&2; return 1 ;;
  esac
}

# -o is checked before anything is submitted. A typo used to start a run and then report failure, so
# the caller's variable was empty while the cluster was busy with a job nobody was waiting for. The
# stub records every apply in a file, so "was anything submitted" is asked of the record and not of the
# script's own output, which it swallows.
test_accelprof_client_rejects_bad_output_before_submitting() {
  local client
  client="$(_ac_client)"
  [ -x "$client" ] || return 2
  local dir out rc fails=0
  dir="$(mktemp -d)"
  mkdir -p "$dir/bin"
  cat >"$dir/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *configmap*) printf 'image.example/accelprof@sha256:aaa\n' ;;
  *"apply -f"*) cat >/dev/null; printf 'submitted\n' >>"${SUBMIT_LOG:?}" ;;
  *"config view"*) printf 'ns\n' ;;
  *conditions*) printf 'Complete \n' ;;
  *run-id*) printf 'RUNID\n' ;;
  *"-l accelprof.io/workload-id="*) printf 'profile-x\n' ;;
esac
STUB
  chmod +x "$dir/bin/kubectl"
  run_client() {
    SUBMIT_LOG="$dir/submits" ACCELPROF_PLATFORM_IMAGE="image.example/accelprof@sha256:aaa" \
      PATH="$dir/bin:$PATH" KUBE_CONTEXT="" "$client" run --alias t-s --namespace ns \
      --image image.example/w:t "$@" -- true 2>&1
  }

  : >"$dir/submits"
  out="$(run_client -o runid)" && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || { printf 'FAIL a bad -o was accepted\n' >&2; fails=$((fails + 1)); }
  case "$out" in *"-o takes id or run-id"*) ;; *) printf 'FAIL bad -o message: %s\n' "$out" >&2; fails=$((fails + 1)) ;; esac
  [ ! -s "$dir/submits" ] || { printf 'FAIL a bad -o submitted the run before failing\n' >&2; fails=$((fails + 1)); }

  # --wait with -o id is refused too, and refused before submitting.
  : >"$dir/submits"
  out="$(run_client --wait -o id)" && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || { printf 'FAIL --wait with -o id was accepted: %s\n' "$out" >&2; fails=$((fails + 1)); }
  case "$out" in *"ask for different things"*) ;; *) printf 'FAIL --wait -o id message: %s\n' "$out" >&2; fails=$((fails + 1)) ;; esac
  [ ! -s "$dir/submits" ] || { printf 'FAIL --wait with -o id submitted the run before failing\n' >&2; fails=$((fails + 1)); }

  # And the accepted forms still submit exactly once.
  : >"$dir/submits"
  out="$(run_client -o id)" && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || { printf 'FAIL -o id was rejected: %s\n' "$out" >&2; fails=$((fails + 1)); }
  [ "$(grep -c . "$dir/submits")" -eq 1 ] || { printf 'FAIL -o id did not submit once\n' >&2; fails=$((fails + 1)); }

  rm -rf "$dir"
  [ "$fails" -eq 0 ] || return 1
}

# get --alias must not answer with a run from another campaign, since the alias is what a reader uses
# to mean "mine" in a namespace several people share.
test_accelprof_client_alias_narrows_the_latest() {
  [ -x "$(_ac_client)" ] || return 2
  local got
  got="$(_ac_run '2026-08-27T05:00:00Z wl-mine 111 Complete
2026-08-27T06:00:00Z wl-theirs 222 Complete' get --alias mine -n team-a)"
  # The stub ignores the label selector, so this asserts the flag reaches the query at all by way of
  # the message naming the alias; the selector itself is covered by the render golden.
  case "$got" in
    0*"for alias mine"*) ;;
    *) printf 'FAIL --alias was not honoured: %s\n' "$got" >&2; return 1 ;;
  esac
}

# The link to the recordings comes from the contract the platform published, and an older contract that
# has no such key must not turn a missing link into a failure — or into a guess, which is what the
# client used to make by reassembling AWS's hostnames from the ARN. Where the URL comes FROM is the data
# layer's business, and mlflow.tf carries the measurement that pins it.
test_accelprof_client_mlflow_url_comes_from_the_contract() {
  local client
  client="$(_ac_client)"
  [ -x "$client" ] || return 2
  local dir out fails=0
  dir="$(mktemp -d)"
  mkdir -p "$dir/bin"
  cat >"$dir/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *ACCELPROF_MLFLOW_UI_URL*) printf '%s\n' "${UI_URL}" ;;
  *ACCELPROF_TRACKING_URI*) printf '%s\n' "${TRACKING_ARN}" ;;
  *go-template*) ;;
  *) ;;
esac
STUB
  chmod +x "$dir/bin/kubectl"
  # get with nothing recorded falls through to the "where the recordings live" hint, which is the one
  # place this URL is printed.
  run_get() {
    UI_URL="$1" TRACKING_ARN="$2" PATH="$dir/bin:$PATH" KUBE_CONTEXT="" "$client" get -n ns 2>&1 || true
  }
  out="$(run_get "https://app-ABC.mlflow.sagemaker.us-east-2.app.aws/" \
    "arn:aws:sagemaker:us-east-2:1:mlflow-app/app-ABC")"
  case "$out" in
    *"https://app-ABC.mlflow.sagemaker.us-east-2.app.aws/"*) ;;
    *) printf 'FAIL the published URL was not shown: %s\n' "$(printf '%s' "$out" | tr '\n' '|')" >&2; fails=$((fails + 1)) ;;
  esac
  # No key in the contract: no link, and no crash either.
  out="$(run_get "" "arn:aws:sagemaker:us-east-2:1:mlflow-tracking-server/srv")"
  case "$out" in
    *https://*) printf 'FAIL a URL was invented with none published: %s\n' "$(printf '%s' "$out" | tr '\n' '|')" >&2; fails=$((fails + 1)) ;;
    *) ;;
  esac
  rm -rf "$dir"
  [ "$fails" -eq 0 ] || return 1
}
