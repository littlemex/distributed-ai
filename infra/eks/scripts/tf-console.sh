#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <module-dir> [terraform-console-args...] <hcl-expr>" >&2
  exit 2
fi

module_dir="$1"
shift
expr="${!#}"
tf_args=()
if [ "$#" -gt 1 ]; then
  tf_args=("${@:1:$(($# - 1))}")
fi

raw=$(printf '%s\n' "$expr" | terraform -chdir="$module_dir" console -no-color "${tf_args[@]}")
# terraform prints config-load diagnostics (e.g. provider deprecation warnings) to stdout ahead of
# the evaluated value. Every expression this helper is used for evaluates to a single-line scalar,
# string, or compact JSON, so the value is the last non-empty line of output.
value=$(printf '%s\n' "$raw" | awk 'NF { last = $0 } END { print last }')
if [[ "$value" == \"*\" ]]; then
  value=${value#\"}
  value=${value%\"}
  value=${value//\\\"/\"}
  value=${value//\\\\/\\}
fi
printf '%s\n' "$value"
