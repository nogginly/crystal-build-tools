#!/usr/bin/env bash
# crystal-linux-static-build
#
# Builds a fully static Crystal binary for Linux using an Alpine container,
# producing a self-contained executable with zero runtime dependencies.
#
# The problem this solves:
#   On macOS, producing a Linux static binary requires a Linux environment.
#   Alpine Linux + musl libc support full static linking via --static, which
#   is not available on macOS or standard glibc Linux distros. Running the
#   build inside an Alpine container gives us a consistent static build
#   environment regardless of the host OS.
#
# How it works:
#   1. Detect podman or docker (podman preferred; override with --engine)
#   2. Pull crystallang/crystal:latest-alpine if not already cached
#   3. Mount the project directory into the container read-only
#   4. Mount the output directory read-write
#   5. Run apk add for any extra Alpine packages needed (e.g. sqlite-static)
#   6. Run shards install + shards build --release --static inside Alpine
#   7. The binary lands in the output path on the host
#
# Usage:
#   crystal-linux-static-build [options] <source.cr>
#
# Options:
#   -o <path>           Output binary path (default: bin/release/<name>-linux)
#   --binary <name>     Binary name as defined in shard.yml targets
#                       (default: derived from source filename)
#   --extra-apks <pkgs> Space-separated Alpine packages to install before build
#                       e.g. --extra-apks "sqlite-static openssl-dev openssl-libs-static"
#   --engine <name>     Container engine to use: podman or docker
#                       (default: auto-detect, podman preferred)
#   --image <image>     Alpine Crystal image to use
#                       (default: crystallang/crystal:latest-alpine)
#   --pre-build <cmd>   Shell command to run inside the container before
#                       shards build, e.g. to compile a web UI
#                       e.g. --pre-build "cd webui && npm i && npm run build && cd .."
#   --release           Pass --release to shards build (default: true)
#   --no-release        Build without --release
#   --keep-container    Don't remove the container after build (for debugging)
#   -v, --verbose       Show all commands as they execute
#   -h, --help          Show this message
#
# Examples:
#   # Basic build — fully static binary for Linux
#   crystal-linux-static-build src/myapp.cr
#
#   # With sqlite3 (e.g. when using crystal-sqlite3 or vecstolite)
#   crystal-linux-static-build src/myapp.cr \
#     --extra-apks "sqlite-static"
#
#   # With a web UI pre-build step and explicit binary name
#   crystal-linux-static-build src/enkaidu.cr \
#     --binary enkaidu \
#     --extra-apks "sqlite-static nodejs npm" \
#     --pre-build "cd webui && npm i && npm run build && cd .."
#
#   # Use docker explicitly
#   crystal-linux-static-build src/myapp.cr --engine docker
#
# Alpine APK reference for common Crystal dependencies:
#   libgc, libevent, pcre2    Already included in crystallang/crystal:latest-alpine
#   sqlite3                   sqlite-static
#   openssl                   openssl-dev openssl-libs-static
#   libxml2                   libxml2-dev libxml2-static
#   libyaml                   yaml-dev yaml-static
#
#   Find packages at: https://pkgs.alpinelinux.org/packages

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

RELEASE=true
VERBOSE=false
KEEP_CONTAINER=false
ENGINE=""
IMAGE="crystallang/crystal:latest-alpine"
SOURCE=""
BINARY=""
OUTPUT=""
EXTRA_APKS=""
PRE_BUILD=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
  sed -n '/^# Usage:/,/^[^#]/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)           usage ;;
    -v|--verbose)        VERBOSE=true;  shift ;;
    --release)           RELEASE=true;  shift ;;
    --no-release)        RELEASE=false; shift ;;
    --keep-container)    KEEP_CONTAINER=true; shift ;;
    -o)                  OUTPUT="$2";       shift 2 ;;
    --binary)            BINARY="$2";       shift 2 ;;
    --extra-apks)        EXTRA_APKS="$2";   shift 2 ;;
    --engine)            ENGINE="$2";       shift 2 ;;
    --image)             IMAGE="$2";        shift 2 ;;
    --pre-build)         PRE_BUILD="$2";    shift 2 ;;
    -*)                  echo "error: unknown option $1" >&2; exit 1 ;;
    *)                   SOURCE="$1";       shift ;;
  esac
done

[[ -z "$SOURCE" ]] && { echo "error: no source file specified" >&2; exit 1; }
[[ -f "$SOURCE" ]] || { echo "error: source file not found: $SOURCE" >&2; exit 1; }

# Derive binary name from source filename if not specified
if [[ -z "$BINARY" ]]; then
  BINARY=$(basename "$SOURCE" .cr)
fi

# Derive output path if not specified
if [[ -z "$OUTPUT" ]]; then
  OUTPUT="bin/release/${BINARY}-linux"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "==> $*"; }
run()  { $VERBOSE && echo "  + $*"; "$@"; }
warn() { echo "warning: $*" >&2; }

# ---------------------------------------------------------------------------
# Detect container engine
# ---------------------------------------------------------------------------

if [[ -n "$ENGINE" ]]; then
  command -v "$ENGINE" &>/dev/null || {
    echo "error: specified engine '$ENGINE' not found" >&2; exit 1
  }
else
  if command -v podman &>/dev/null; then
    ENGINE="podman"
  elif command -v docker &>/dev/null; then
    ENGINE="docker"
  else
    echo "error: neither podman nor docker found" >&2
    echo "       Install one of: https://podman.io  https://docker.com" >&2
    exit 1
  fi
fi

log "Using container engine: $ENGINE"

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------

PROJECT_DIR=$(pwd)
OUTPUT_DIR=$(dirname "$OUTPUT")
OUTPUT_FILENAME=$(basename "$OUTPUT")

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)  # absolute path

# ---------------------------------------------------------------------------
# Build the in-container script
# ---------------------------------------------------------------------------

SHARDS_BUILD_ARGS="--release"
$RELEASE || SHARDS_BUILD_ARGS=""

# Construct the shell script that runs inside Alpine
CONTAINER_SCRIPT="set -e"

# Install extra Alpine packages if requested
if [[ -n "$EXTRA_APKS" ]]; then
  CONTAINER_SCRIPT+="
apk add --no-cache $EXTRA_APKS"
fi

# Copy project to a writable workspace (project is mounted read-only)
CONTAINER_SCRIPT+="
cp -r /project /workspace
cd /workspace"

# Optional pre-build step (e.g. web UI compilation)
if [[ -n "$PRE_BUILD" ]]; then
  CONTAINER_SCRIPT+="
$PRE_BUILD"
fi

# Install shards and build
CONTAINER_SCRIPT+="
shards --production check || shards --production install
shards build $BINARY $SHARDS_BUILD_ARGS --static
cp bin/$BINARY /output/$OUTPUT_FILENAME"

$VERBOSE && {
  echo "  Container script:"
  echo "$CONTAINER_SCRIPT" | sed 's/^/    /'
}

# ---------------------------------------------------------------------------
# Run the container
# ---------------------------------------------------------------------------

log "Building $BINARY for Linux (static) in $IMAGE..."

CONTAINER_ARGS=(
  "--rm"
  "--volume" "$PROJECT_DIR:/project:ro"
  "--volume" "$OUTPUT_DIR:/output"

)

$KEEP_CONTAINER && CONTAINER_ARGS=("${CONTAINER_ARGS[@]/--rm/}")

run "$ENGINE" run \
  "${CONTAINER_ARGS[@]}" \
  "$IMAGE" \
  sh -c "$CONTAINER_SCRIPT"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

RESULT="$OUTPUT_DIR/$OUTPUT_FILENAME"

[[ -f "$RESULT" ]] || {
  echo "error: expected binary not found at $OUTPUT" >&2; exit 1
}

# Check the binary is actually a static Linux ELF
FILE_INFO=$(file "$RESULT" 2>/dev/null || echo "unknown")
if echo "$FILE_INFO" | grep -q "statically linked"; then
  log "Verified: statically linked ELF binary"
elif echo "$FILE_INFO" | grep -q "ELF"; then
  warn "Binary is an ELF but may not be fully static: $FILE_INFO"
else
  warn "Could not verify binary type: $FILE_INFO"
fi

log "Built: $OUTPUT"
