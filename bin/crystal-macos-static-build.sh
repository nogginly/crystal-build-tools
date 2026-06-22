#!/usr/bin/env bash
# crystal-macos-static-build
#
# Builds a Crystal program on macOS with all non-system libraries linked
# statically, producing a binary that only depends on Apple's own
# libSystem and libiconv (both guaranteed on every macOS installation).
#
# The problem this solves:
#   Crystal hardcodes -L<cellar-path> flags into every link command, and
#   macOS ld prefers .dylib over .a when both exist in a search path.
#   No --link-flags trick can override this. The only solution is to
#   separate compilation (crystal --emit obj) from linking (cc), so we
#   control the link command entirely.
#
# How it works:
#   1. Run crystal build --verbose to discover which -l flags Crystal uses
#   2. Copy the corresponding .a files into a temp dir (no .dylib siblings)
#   3. Compile the source to an object file with --emit obj
#   4. Link manually: cc <obj> -L<static-dir> <discovered -l flags>
#   5. Verify with otool -L (only system libs should remain)
#
# Usage:
#   crystal-macos-static-build [options] <source.cr>
#
# Options:
#   -o <path>        Output binary path (default: derived from source filename)
#   -l <name>        Additional static lib to include (repeatable)
#                    e.g. -l ssl -l crypto -l xml2
#   --static-dir <d> Directory containing .a files (default: auto-resolved
#                    from $(brew --prefix)/lib and $(brew --prefix)/opt/)
#   --release        Pass --release to crystal build (default: true)
#   --no-release     Build without --release
#   --verify         Run otool -L on the result and warn if non-system dylibs
#                    are found (default: true)
#   --no-verify      Skip otool verification
#   --keep-tmp       Keep the temp staging dir after build (for debugging)
#   -v, --verbose    Show all commands as they execute
#   -h, --help       Show this message
#
# Examples:
#   # Basic build — auto-discovers Crystal's deps, links statically
#   crystal-macos-static-build src/enkaidu.cr
#
#   # With additional libs (e.g. openssl, sqlite for when vecstolite lands)
#   crystal-macos-static-build src/enkaidu.cr \
#     -l ssl -l crypto -l sqlite3 -l xml2 -l yaml
#
#   # Custom output path
#   crystal-macos-static-build -o bin/release/enkaidu src/enkaidu.cr
#
# System libs that are always left dynamic (safe — Apple guarantees these):
#   /usr/lib/libSystem.B.dylib
#   /usr/lib/libiconv.2.dylib

set -euo pipefail

# ---------------------------------------------------------------------------
# Platform guard
# ---------------------------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "error: crystal-macos-static-build is macOS only" >&2
  echo "       On Linux, use: shards build --release --static" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

RELEASE=true
VERIFY=true
KEEP_TMP=false
VERBOSE=false
OUTPUT=""
EXTRA_LIBS=()     # additional -l names provided via -l flags
SOURCE=""
BREW=$(brew --prefix 2>/dev/null) || { echo "error: brew not found" >&2; exit 1; }

# System libs we intentionally leave dynamic — Apple guarantees these
SYSTEM_LIBS=("libSystem" "libiconv")

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
  sed -n '/^# Usage:/,/^[^#]/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)       usage ;;
    -v|--verbose)    VERBOSE=true;  shift ;;
    --release)       RELEASE=true;  shift ;;
    --no-release)    RELEASE=false; shift ;;
    --verify)        VERIFY=true;   shift ;;
    --no-verify)     VERIFY=false;  shift ;;
    --keep-tmp)      KEEP_TMP=true; shift ;;
    -o)              OUTPUT="$2";   shift 2 ;;
    -l)              EXTRA_LIBS+=("$2"); shift 2 ;;
    --static-dir)    STATIC_DIR_OVERRIDE="$2"; shift 2 ;;
    -*)              echo "error: unknown option $1" >&2; exit 1 ;;
    *)               SOURCE="$1";   shift ;;
  esac
done

[[ -z "$SOURCE" ]] && { echo "error: no source file specified" >&2; exit 1; }
[[ -f "$SOURCE" ]] || { echo "error: source file not found: $SOURCE" >&2; exit 1; }

# Resolve OUTPUT to absolute path now, before we cd — it may be relative
# to the caller's working directory.
if [[ -n "$OUTPUT" ]]; then
  OUTPUT_DIR_ABS=$(mkdir -p "$(dirname "$OUTPUT")" && cd "$(dirname "$OUTPUT")" && pwd)
  OUTPUT="$OUTPUT_DIR_ABS/$(basename "$OUTPUT")"
fi

# Resolve project root by walking up from the source file to find shard.yml.
# Falls back to the source file's directory if no shard.yml is found.
SOURCE_ABS=$(cd "$(dirname "$SOURCE")" && pwd)/$(basename "$SOURCE")
SOURCE_DIR=$(dirname "$SOURCE_ABS")

PROJECT_DIR="$SOURCE_DIR"
_search="$SOURCE_DIR"
while [[ "$_search" != "/" ]]; do
  if [[ -f "$_search/shard.yml" ]]; then
    PROJECT_DIR="$_search"
    break
  fi
  _search=$(dirname "$_search")
done

cd "$PROJECT_DIR"

# Re-resolve SOURCE relative to PROJECT_DIR now that we've cd'd
SOURCE=$(python3 -c "import os; print(os.path.relpath('$SOURCE_ABS', '$PROJECT_DIR'))")

# Derive output path from source filename if not specified
if [[ -z "$OUTPUT" ]]; then
  BASENAME=$(basename "$SOURCE" .cr)
  OUTPUT="bin/release/$BASENAME"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "==> $*"; }
run()  { $VERBOSE && echo "  + $*"; "$@"; }
warn() { echo "warning: $*" >&2; }

# Find a .a file for a given lib name, searching Homebrew's prefix and opt/
find_static_lib() {
  local name="$1"  # e.g. "gc", "pcre2-8", "ssl"

  # Common search locations in priority order
  local candidates=(
    "$BREW/lib/lib${name}.a"
    "$BREW/opt/${name}/lib/lib${name}.a"
    # Handle names like "ssl" that live under "openssl@3"
    "$BREW/opt/openssl@3/lib/lib${name}.a"
    "$BREW/opt/libxml2/lib/lib${name}.a"
    "$BREW/opt/sqlite/lib/lib${name}.a"
    "$BREW/opt/libyaml/lib/lib${name}.a"
  )

  for path in "${candidates[@]}"; do
    [[ -f "$path" ]] && { echo "$path"; return 0; }
  done

  return 1  # not found — caller decides if this is fatal
}

is_system_lib() {
  local name="$1"
  for sys in "${SYSTEM_LIBS[@]}"; do
    [[ "$name" == "$sys"* ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Step 1: Discover Crystal's -l flags via a verbose dry-run
# ---------------------------------------------------------------------------

log "Discovering Crystal link flags (dry-run)..."

CRYSTAL_ARGS=()
$RELEASE && CRYSTAL_ARGS+=(--release)

# Run crystal build --verbose, capture stderr where the cc command is printed,
# extract the cc ... line, then pull out all -l<name> tokens.
VERBOSE_OUTPUT=$(crystal build "$SOURCE" "${CRYSTAL_ARGS[@]}" \
  --emit obj -o /tmp/_crystal_static_probe --verbose 2>&1 || true)

CC_LINE=$(echo "$VERBOSE_OUTPUT" | grep '^cc ' | tail -1)

if [[ -z "$CC_LINE" ]]; then
  echo "error: could not extract cc command from crystal --verbose output" >&2
  echo "Full output:" >&2
  echo "$VERBOSE_OUTPUT" >&2
  exit 1
fi

$VERBOSE && echo "  Discovered link command: $CC_LINE"

# Extract -l<name> flags from the cc line, stripping the -l prefix
DISCOVERED_LIBS=()
for token in $CC_LINE; do
  if [[ "$token" == -l* ]]; then
    DISCOVERED_LIBS+=("${token#-l}")
  fi
done

log "Crystal links against: ${DISCOVERED_LIBS[*]:-none}"

# Also pick up the object file Crystal compiled
OBJ_FILE="/tmp/_crystal_static_probe.o"
[[ -f "$OBJ_FILE" ]] || {
  # crystal may have named it differently; try to find it
  OBJ_FILE=$(echo "$VERBOSE_OUTPUT" | grep -o '/tmp/[^ ]*\.o' | head -1)
}
[[ -f "$OBJ_FILE" ]] || { echo "error: compiled object file not found" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 2: Set up static-only staging directory
# ---------------------------------------------------------------------------

if [[ -n "${STATIC_DIR_OVERRIDE:-}" ]]; then
  STATIC_DIR="$STATIC_DIR_OVERRIDE"
  log "Using provided static lib dir: $STATIC_DIR"
else
  STATIC_DIR=$(mktemp -d)
  log "Staging static libs in: $STATIC_DIR"

  # Combine discovered libs + any extra libs specified via -l
  ALL_LIBS=("${DISCOVERED_LIBS[@]}" ${EXTRA_LIBS[@]+"${EXTRA_LIBS[@]}"})

  LINKED_LIBS=()    # libs we found .a for — will pass to linker
  DYNAMIC_LIBS=()   # libs we couldn't find .a for — left dynamic

  for lib in "${ALL_LIBS[@]}"; do
    if is_system_lib "$lib"; then
      # Leave system libs dynamic — don't try to stage them
      LINKED_LIBS+=("$lib")
      continue
    fi

    if static_path=$(find_static_lib "$lib"); then
      run cp "$static_path" "$STATIC_DIR/"
      LINKED_LIBS+=("$lib")
      log "  [static] $lib  ← $static_path"
    else
      warn "no .a found for -l$lib — will link dynamically"
      DYNAMIC_LIBS+=("$lib")
      LINKED_LIBS+=("$lib")
    fi
  done
fi

# ---------------------------------------------------------------------------
# Step 3: Compile source to object file
# ---------------------------------------------------------------------------

log "Compiling $SOURCE..."

OBJ_OUT="/tmp/$(basename "$SOURCE" .cr)_static.o"
run crystal build "$SOURCE" "${CRYSTAL_ARGS[@]}" --emit obj -o "${OBJ_OUT%.o}"

[[ -f "$OBJ_OUT" ]] || { echo "error: object file not produced at $OBJ_OUT" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 4: Link manually — full control, no Crystal-injected -L paths
# ---------------------------------------------------------------------------

log "Linking $OUTPUT..."

mkdir -p "$(dirname "$OUTPUT")"

# Build the -l flags list for the link command
L_FLAGS=()
for lib in "${LINKED_LIBS[@]}"; do
  L_FLAGS+=("-l$lib")
done

run cc "$OBJ_OUT" \
  -o "$OUTPUT" \
  -L"$STATIC_DIR" \
  "${L_FLAGS[@]}" \
  -rdynamic

# ---------------------------------------------------------------------------
# Step 5: Verify — only system libs should remain
# ---------------------------------------------------------------------------

if $VERIFY; then
  log "Verifying dynamic dependencies..."
  OTOOL_OUT=$(otool -L "$OUTPUT")
  echo "$OTOOL_OUT"

  UNEXPECTED=()
  while IFS= read -r line; do
    # Extract the dylib path from each otool line
    dylib=$(echo "$line" | awk '{print $1}')
    [[ -z "$dylib" || "$dylib" == "$OUTPUT:" ]] && continue
    # Flag anything not in /usr/lib
    if [[ "$dylib" != /usr/lib/* ]]; then
      UNEXPECTED+=("$dylib")
    fi
  done <<< "$OTOOL_OUT"

  if [[ ${#UNEXPECTED[@]} -gt 0 ]]; then
    warn "non-system dynamic dependencies remain:"
    for u in "${UNEXPECTED[@]}"; do
      warn "  $u"
    done
    warn "The binary may not run on machines without these libraries installed."
  else
    log "All good — only system libraries remain dynamic."
  fi
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

$KEEP_TMP || [[ -z "${STATIC_DIR_OVERRIDE:-}" ]] && {
  $KEEP_TMP || rm -rf "$STATIC_DIR"
}
rm -f "$OBJ_OUT" "/tmp/_crystal_static_probe.o"

log "Built: $OUTPUT"
