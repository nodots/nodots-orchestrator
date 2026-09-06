#!/usr/bin/env bash
# Proves the CI job actually executes a test in this directory and that the
# shared assertions report both outcomes. Working agreements §3: a gate that
# has never run is not a gate, so the workflow ships green before any real
# test depends on it.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

assert_eq "a" "a" "assert_eq matches"
assert_ne "a" "b" "assert_ne separates"
assert_contains "hello world" "lo wo" "assert_contains finds a substring"
assert_not_contains "hello world" "zebra" "assert_not_contains rejects an absent substring"
assert_nonempty "x" "assert_nonempty accepts a value"
assert_empty "" "assert_empty accepts nothing"
assert_file "./lib.sh" "assert_file finds the shared library"

# The failure path must report, not throw.
out=$(TESTS_RUN=0 TESTS_FAILED=0; _fail "deliberate" "detail"; printf '%d' "$TESTS_FAILED")
assert_contains "$out" "FAIL  deliberate" "a failing assertion prints FAIL"
assert_contains "$out" "1" "a failing assertion increments the counter"

finish
