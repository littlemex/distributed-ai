#!/usr/bin/env bash
# Static regression tests. Files under cases/ group functions by area; each test's layer and suite
# are declared in registry.sh (the single source). Static tests read Terraform state / chart sources
# only and never touch the cluster.

terraform_static_ready() {
  terraform -chdir="$SCRIPT_DIR/.." providers >/dev/null 2>&1 \
    && printf 'true\n' | terraform -chdir="$SCRIPT_DIR/.." console -no-color >/dev/null 2>&1
}

test_static_terraform_validate() {
  terraform_static_ready || return 2
  terraform -chdir="$SCRIPT_DIR/.." validate -no-color
}
