#!/usr/bin/env bash
# Suite selection helpers.

suite_rank() {
  case "$1" in
    baseline) echo 1 ;;
    coverage) echo 2 ;;
    full) echo 3 ;;
    *) return 1 ;;
  esac
}

valid_suite() {
  suite_rank "$1" >/dev/null 2>&1
}

valid_layer() {
  case "$1" in
    static | live-ro | live-mut | gpu) return 0 ;;
    *) return 1 ;;
  esac
}

test_selected() {
  local min_suite="$1" layer="$2" skip_layer extra_layer
  for skip_layer in $SKIP_LAYERS; do
    [ "$skip_layer" = "$layer" ] && return 1
  done
  for extra_layer in $EXTRA_LAYERS; do
    [ "$extra_layer" = "$layer" ] && return 0
  done
  [ "$(suite_rank "$min_suite")" -le "$(suite_rank "$SUITE")" ]
}

tools_available() {
  local tool
  for tool in "$@"; do
    [ -z "$tool" ] && continue
    command -v "$tool" >/dev/null 2>&1 || return 1
  done
  return 0
}
