#!/usr/bin/env bash
# test/test-linux.sh
#
# Integration tests for crystal-linux-static-build.
#
# Run from the repo root:
#   test/test-linux.sh
#
# Or with verbose script output:
#   VERBOSE=1 test/test-linux.sh
#
# Requires podman or docker to be available.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO_ROOT/bin/crystal-linux-static-build.sh"
FIXTURES="$REPO_ROOT/test/fixtures"
OUT="$REPO_ROOT/test/output/linux"

source "$REPO_ROOT/test/lib/helpers.sh"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

[[ -x "$SCRIPT" ]] || { echo "error: script not found or not executable: $SCRIPT" >&2; exit 1; }

# Detect arch for expected output filenames
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
  x86_64|amd64)   ARCH="amd64" ;;
  aarch64|arm64)  ARCH="arm64" ;;
  *) echo "error: unsupported architecture: $HOST_ARCH" >&2; exit 1 ;;
esac

mkdir -p "$OUT"
rm -f "$OUT"/*

VERBOSE_FLAG=""
[[ "${VERBOSE:-}" == "1" ]] && VERBOSE_FLAG="-v"

echo ""
_bold "crystal-linux-static-build — integration tests"
echo "  Script:   $SCRIPT"
echo "  Fixtures: $FIXTURES"
echo "  Output:   $OUT"
echo "  Arch:     $ARCH"
echo ""

# ---------------------------------------------------------------------------
# Fixture: hello — basic build, no C deps
# ---------------------------------------------------------------------------

echo "$(_bold 'Fixture: hello')"

run_test "builds successfully" \
  "$SCRIPT" $VERBOSE_FLAG \
    "$FIXTURES/hello/src/hello.cr" \
    --binary hello \
    -o "$OUT/hello-linux-$ARCH"

run_test "binary exists" \
  assert_file "$OUT/hello-linux-$ARCH"

run_test "binary is a static ELF" \
  assert_static_elf "$OUT/hello-linux-$ARCH"

# Note: running the Linux binary on macOS isn't possible without emulation.
# On Linux runners the binary can be executed directly.
if [[ "$(uname -s)" == "Linux" ]]; then
  run_test "binary runs and exits 0" \
    assert_runs "$OUT/hello-linux-$ARCH"

  run_test "binary produces expected output" \
    assert_output_contains "$OUT/hello-linux-$ARCH" "hello from crystal-build-tools test"
else
  info "skipping run tests (host is macOS; binary is Linux ELF)"
fi

echo ""

# ---------------------------------------------------------------------------
# Fixture: hello-sqlite — --extra-apks path
# ---------------------------------------------------------------------------

echo "$(_bold 'Fixture: hello-sqlite')"

run_test "builds successfully with --extra-apks sqlite-static" \
  "$SCRIPT" $VERBOSE_FLAG \
    "$FIXTURES/hello-sqlite/src/hello-sqlite.cr" \
    --binary hello-sqlite \
    -o "$OUT/hello-sqlite-linux-$ARCH" \
    --extra-apks "sqlite-static"

run_test "binary exists" \
  assert_file "$OUT/hello-sqlite-linux-$ARCH"

run_test "binary is a static ELF" \
  assert_static_elf "$OUT/hello-sqlite-linux-$ARCH"

if [[ "$(uname -s)" == "Linux" ]]; then
  run_test "binary runs and exits 0" \
    assert_runs "$OUT/hello-sqlite-linux-$ARCH"

  run_test "binary produces expected output" \
    assert_output_contains "$OUT/hello-sqlite-linux-$ARCH" \
      "hello from crystal-build-tools sqlite test"
else
  info "skipping run tests (host is macOS; binary is Linux ELF)"
fi

echo ""

# ---------------------------------------------------------------------------
# Fixture: hello-webui — --pre-build path
# ---------------------------------------------------------------------------

echo "$(_bold 'Fixture: hello-webui')"

run_test "builds successfully with --pre-build step" \
  "$SCRIPT" $VERBOSE_FLAG \
    "$FIXTURES/hello-webui/src/hello-webui.cr" \
    --binary hello-webui \
    -o "$OUT/hello-webui-linux-$ARCH" \
    --extra-apks "nodejs npm" \
    --pre-build "cd webui && npm run build && cd .."

run_test "binary exists" \
  assert_file "$OUT/hello-webui-linux-$ARCH"

run_test "binary is a static ELF" \
  assert_static_elf "$OUT/hello-webui-linux-$ARCH"

if [[ "$(uname -s)" == "Linux" ]]; then
  run_test "binary runs and exits 0" \
    assert_runs "$OUT/hello-webui-linux-$ARCH"

  run_test "binary produces expected output" \
    assert_output_contains "$OUT/hello-webui-linux-$ARCH" \
      "hello from crystal-build-tools webui test"
else
  info "skipping run tests (host is macOS; binary is Linux ELF)"
fi

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

run_test "unsupported engine fails with error" \
  bash -c "! $SCRIPT --engine notacontainer src/foo.cr 2>/dev/null"

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary "crystal-linux-static-build"
