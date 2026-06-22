#!/usr/bin/env bash
# test/test-macos.sh
#
# Integration tests for crystal-macos-static-build.
#
# Run from the repo root:
#   test/test-macos.sh
#
# Or with verbose script output:
#   VERBOSE=1 test/test-macos.sh

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO_ROOT/bin/crystal-macos-static-build.sh"
FIXTURES="$REPO_ROOT/test/fixtures"
OUT="$REPO_ROOT/test/output/macos"

source "$REPO_ROOT/test/lib/helpers.sh"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "error: test-macos.sh must run on macOS" >&2; exit 1
}

[[ -x "$SCRIPT" ]] || { echo "error: script not found or not executable: $SCRIPT" >&2; exit 1; }

mkdir -p "$OUT"
rm -f "$OUT"/*

VERBOSE_FLAG=""
[[ "${VERBOSE:-}" == "1" ]] && VERBOSE_FLAG="-v"

echo ""
_bold "crystal-macos-static-build — integration tests"
echo "  Script:   $SCRIPT"
echo "  Fixtures: $FIXTURES"
echo "  Output:   $OUT"
echo ""

# ---------------------------------------------------------------------------
# Fixture: hello — basic build, no C deps
# ---------------------------------------------------------------------------

echo "$(_bold 'Fixture: hello')"

run_test "builds successfully" \
  "$SCRIPT" $VERBOSE_FLAG \
    "$FIXTURES/hello/src/hello.cr" \
    -o "$OUT/hello"

run_test "binary exists" \
  assert_file "$OUT/hello"

run_test "only system dylibs" \
  assert_only_system_dylibs "$OUT/hello"

run_test "binary runs and exits 0" \
  assert_runs "$OUT/hello"

run_test "binary produces expected output" \
  assert_output_contains "$OUT/hello" "hello from crystal-build-tools test"

echo ""

# ---------------------------------------------------------------------------
# Fixture: hello-sqlite — --extra-libs path (macOS: keg-only sqlite)
# ---------------------------------------------------------------------------

echo "$(_bold 'Fixture: hello-sqlite')"

run_test "install shards" \
  bash -c "cd '$FIXTURES/hello-sqlite' && shards --production install"

run_test "builds successfully with sqlite3" \
  "$SCRIPT" $VERBOSE_FLAG \
    "$FIXTURES/hello-sqlite/src/hello-sqlite.cr" \
    -o "$OUT/hello-sqlite" \
    -l sqlite3

run_test "binary exists" \
  assert_file "$OUT/hello-sqlite"

run_test "only system dylibs" \
  assert_only_system_dylibs "$OUT/hello-sqlite"

run_test "binary runs and exits 0" \
  assert_runs "$OUT/hello-sqlite"

run_test "binary produces expected output" \
  assert_output_contains "$OUT/hello-sqlite" "hello from crystal-build-tools sqlite test"

echo ""

# ---------------------------------------------------------------------------
# Fixture: hello-webui — --pre-build path
# ---------------------------------------------------------------------------

echo "$(_bold 'Fixture: hello-webui')"

run_test "install shards" \
  bash -c "cd '$FIXTURES/hello-webui' && shards --production install"

run_test "builds successfully with pre-build step" \
  "$SCRIPT" $VERBOSE_FLAG \
    "$FIXTURES/hello-webui/src/hello-webui.cr" \
    -o "$OUT/hello-webui"

run_test "binary exists" \
  assert_file "$OUT/hello-webui"

run_test "only system dylibs" \
  assert_only_system_dylibs "$OUT/hello-webui"

run_test "binary runs and exits 0" \
  assert_runs "$OUT/hello-webui"

run_test "binary produces expected output" \
  assert_output_contains "$OUT/hello-webui" "hello from crystal-build-tools webui test"

echo ""

# ---------------------------------------------------------------------------
# CLI behaviour
# ---------------------------------------------------------------------------

echo "$(_bold 'CLI behaviour')"

run_test "--help exits 0" \
  bash -c "$SCRIPT --help > /dev/null"

run_test "missing source file fails with error" \
  bash -c "! $SCRIPT nonexistent.cr 2>/dev/null"

run_test "unknown option fails with error" \
  bash -c "! $SCRIPT --not-a-flag src/foo.cr 2>/dev/null"

run_test "fails on non-macOS (guard check)" \
  bash -c "uname -s | grep -q Darwin"

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary "crystal-macos-static-build"
