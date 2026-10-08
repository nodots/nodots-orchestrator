# Shared assertions for the fixture tests. Sourced by *.test.sh, never run alone.
#
# A test script sources this, calls the assert_* helpers, and ends with `finish`.
# Exit 0 means every assertion held; exit 1 means at least one did not.

TESTS_RUN=0
TESTS_FAILED=0

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  ok    %s\n' "$1"; }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '        %s\n' "$2"
  return 0
}

# assert_eq <expected> <actual> <label>
assert_eq() {
  if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3" "expected [$1], got [$2]"; fi
}

# assert_ne <not-expected> <actual> <label>
assert_ne() {
  if [ "$1" != "$2" ]; then _pass "$3"; else _fail "$3" "expected anything but [$1]"; fi
}

# assert_contains <haystack> <needle> <label>
assert_contains() {
  case "$1" in
    *"$2"*) _pass "$3" ;;
    *) _fail "$3" "[$1] does not contain [$2]" ;;
  esac
}

# assert_not_contains <haystack> <needle> <label>
assert_not_contains() {
  case "$1" in
    *"$2"*) _fail "$3" "[$1] unexpectedly contains [$2]" ;;
    *) _pass "$3" ;;
  esac
}

# assert_nonempty <value> <label>
assert_nonempty() {
  if [ -n "$1" ]; then _pass "$2"; else _fail "$2" "value was empty"; fi
}

# assert_empty <value> <label>
assert_empty() {
  if [ -z "$1" ]; then _pass "$2"; else _fail "$2" "expected empty, got [$1]"; fi
}

# assert_file <path> <label>
assert_file() {
  if [ -f "$1" ]; then _pass "$2"; else _fail "$2" "no such file: $1"; fi
}

# finish — print the tally and set the script's exit status.
finish() {
  printf '  --- %d checks, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ] || exit 1
  exit 0
}
