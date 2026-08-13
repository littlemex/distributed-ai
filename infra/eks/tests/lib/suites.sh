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

# 'neuron' is a standalone suite, not part of the baseline<coverage<full ladder: it needs Trainium
# capacity (a region-specific Capacity Block) that most environments lack, so it must never be
# pulled in by the regular suites. It has no rank.
valid_suite() {
  case "$1" in
    baseline | coverage | full | neuron) return 0 ;;
    *) return 1 ;;
  esac
}

valid_layer() {
  case "$1" in
    static | live-ro | live-mut | gpu | neuron) return 0 ;;
    *) return 1 ;;
  esac
}

test_selected() {
  local min_suite="$1" layer="$2" skip_layer extra_layer
  for skip_layer in $SKIP_LAYERS; do
    [ "$skip_layer" = "$layer" ] && return 1
  done
  # The 'neuron' suite runs ONLY the opt-in neuron layer; every other suite never runs it. This
  # keeps the Trainium-only, region-dependent test out of baseline/coverage/full while letting
  # `--suite neuron` run it alone.
  if [ "$SUITE" = neuron ]; then
    [ "$layer" = neuron ]
    return
  fi
  [ "$layer" = neuron ] && return 1
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
