#!/usr/bin/env bash
# Off-hardware unit tests for netkit's pure helpers. Zero deps. Run from repo root:
#   bash tests/run.sh
# Sources netkit via the NETKIT_LIB guard, then exercises pure functions with
# subshell-isolated command stubs. Exit 0 = all pass; non-zero = a failure.

# Dynamic source: netkit defines functions we load conditionally; cannot be statically traced by shellcheck.
# shellcheck disable=SC1091
NETKIT_LIB=1 source ./netkit || { echo "cannot source ./netkit (run from repo root)"; exit 2; }

fails="$(mktemp)"; trap 'rm -f "$fails"' EXIT

assert_eq()       { if [ "$1" = "$2" ]; then printf '  ok: %s\n' "$3"; else printf '  FAIL: %s (want [%s] got [%s])\n' "$3" "$1" "$2"; echo x >>"$fails"; fi; }
assert_empty()    { if [ -z "$1" ]; then printf '  ok: %s\n' "$2"; else printf '  FAIL: %s (got [%s])\n' "$2" "$1"; echo x >>"$fails"; fi; }
assert_contains() { case "$1" in *"$2"*) printf '  ok: %s\n' "$3" ;; *) printf '  FAIL: %s (missing [%s])\n' "$3" "$2"; echo x >>"$fails" ;; esac; }
assert_rc()       { if [ "$1" = "$2" ]; then printf '  ok: %s\n' "$3"; else printf '  FAIL: %s (want rc %s got %s)\n' "$3" "$1" "$2"; echo x >>"$fails"; fi; }

# run_test, NOT run — netkit defines its own run() helper, which we just sourced.
run_test() { printf '== %s ==\n' "$1"; ( "$1" ); }

test_smoke() { assert_eq "8" "8" "harness sanity"; }

run_test test_smoke

n="$(wc -l <"$fails" | tr -d ' ')"
printf '\n%s failure(s)\n' "$n"
[ "$n" -eq 0 ]
