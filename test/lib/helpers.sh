#!/usr/bin/env bash
# test/lib/helpers.sh
#
# Shared helpers for crystal-build-tools integration tests.
# Source this file; do not run it directly.

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

_green()  { printf '\033[0;32m%s\033[0m' "$*"; }
_red()    { printf '\033[0;31m%s\033[0m' "$*"; }
_yellow() { printf '\033[0;33m%s\033[0m' "$*"; }
_bold()   { printf '\033[1m%s\033[0m' "$*"; }

pass() { echo "  $(_green '✓') $*"; }
fail() { echo "  $(_red '✗') $*"; }
info() { echo "  $(_yellow '→') $*"; }

# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

# Run a named test. Usage: run_test "description" <command...>
# Records pass/fail; does not abort on failure.
run_test() {
  local description="$1"; shift
  TESTS_RUN=$((TESTS_RUN + 1))

  if "$@" > /tmp/test_output 2>&1; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    pass "$description"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_TESTS+=("$description")
    fail "$description"
    # Show output on failure to aid diagnosis
    sed 's/^/      /' /tmp/test_output >&2
  fi
}

# Assert a file exists
assert_file() {
  local path="$1"
  [[ -f "$path" ]] || { echo "expected file not found: $path" >&2; return 1; }
}

# Assert a command's output contains a string
assert_output_contains() {
  local cmd="$1"
  local expected="$2"
  local actual
  actual=$($cmd 2>&1) || true
  echo "$actual" | grep -qF "$expected" || {
    echo "expected '$expected' in output of: $cmd" >&2
    echo "actual output: $actual" >&2
    return 1
  }
}

# Assert binary runs and exits 0
assert_runs() {
  local binary="$1"
  [[ -x "$binary" ]] || { echo "not executable: $binary" >&2; return 1; }
  "$binary" > /dev/null 2>&1 || {
    echo "binary exited with error: $binary" >&2
    return 1
  }
}

# Assert otool -L shows only system dylibs (macOS only)
assert_only_system_dylibs() {
  local binary="$1"
  [[ -f "$binary" ]] || { echo "binary not found: $binary" >&2; return 1; }
  local libs
  libs=$(otool -L "$binary" | tail -n +2 | awk '{print $1}')
  local non_system
  non_system=$(echo "$libs" | grep -v '^/usr/lib/' || true)
  if [[ -n "$non_system" ]]; then
    echo "non-system dylibs found in $binary:" >&2
    echo "$non_system" >&2
    return 1
  fi
}

# Assert binary is a statically linked ELF (Linux only)
assert_static_elf() {
  local binary="$1"
  local info
  info=$(file "$binary")
  echo "$info" | grep -q "ELF" || {
    echo "not an ELF binary: $info" >&2; return 1
  }
  echo "$info" | grep -q "statically linked" || {
    echo "not statically linked: $info" >&2; return 1
  }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
  local suite="$1"
  echo ""
  _bold "Results: $suite"
  echo ""
  echo "  Passed: $(_green $TESTS_PASSED)"
  echo "  Failed: $(_red $TESTS_FAILED)"
  echo "  Total:  $TESTS_RUN"

  if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    echo ""
    echo "  Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
      echo "    $(_red '✗') $t"
    done
  fi

  echo ""
  [[ $TESTS_FAILED -eq 0 ]]  # exit 0 on all pass, 1 on any failure
}
