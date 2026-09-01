#!/usr/bin/env bash
# The reader's own bash assembles what the tools submit, and bash changed what a substitution does with
# its replacement text: '&' means the matched text, and a backslash escapes it, only from 5.2. Code
# written for one era corrupts the other on the machine of whoever has the other one. Measured: bash
# 3.2.57 and 5.1.16 insert a replacement verbatim, 5.2.37 interprets it, and `kubectl accelprof run
# --gpu 1` failed on the first two with "found unknown escape character" while passing on the third.
#
# Requiring a newer bash is not the answer: Apple ships 3.2 and does not update it, so a version gate
# exports the problem to every Mac reader. The rule is that nothing a reader runs may need more than
# 3.2, and the CI job of the same name renders the manifests under five versions and diffs them. This
# runs the cheap half here too, so the rule is enforced before a pull request exists.
test_no_reader_script_needs_a_modern_bash() {
  local script="$SCRIPT_DIR/portability/no-modern-bash.sh"
  [ -x "$script" ] || { printf 'no-modern-bash.sh is missing or not executable\n' >&2; return 1; }
  local out rc=0
  out="$("$script" 2>&1)" || rc=$?
  [ "$rc" = "0" ] || { printf '%s\n' "$out" >&2; return 1; }
}

# A registered test whose function is never sourced does not fail as a missing assertion: the runner
# calls a name that does not exist and the case reports exit 127. That is what happened when the file
# above was added — registered, written, and left out of the runner's explicit list of files to source,
# so it counted as a failure without ever having run. The list is explicit on purpose, and this is what
# makes forgetting it loud at the moment it happens rather than at the next full run.
test_every_registered_test_is_reachable() {
  command -v python3 >/dev/null || return 2
  python3 "$SCRIPT_DIR/portability/registered-tests-are-reachable.py" "$SCRIPT_DIR" || return 1
}
