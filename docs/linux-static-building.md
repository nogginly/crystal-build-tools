# Static Builds for Linux with Crystal

This document explains the approach used by `crystal-linux-static-build` to
produce fully static Crystal binaries for Linux from any host OS.

## Background

On Alpine Linux, Crystal supports full static linking out of the box:

```sh
shards build --release --static
```

Alpine uses musl libc, which — unlike glibc — supports fully static
executables. The result is a single binary with zero runtime dependencies that
runs on any Linux of the same CPU architecture, regardless of what libraries
are installed.

The challenge is producing this binary from a macOS development machine, or
from a standard glibc Linux distro (Ubuntu, Debian, etc.) where `--static`
doesn't work cleanly. The solution is to run the build inside an Alpine
container.

## How it works

```
Host (macOS or Linux)
  │
  └── podman / docker run crystallang/crystal:latest-alpine
          │
          ├── apk add <extra-apks>       ← optional extra Alpine packages
          ├── cp /project /workspace     ← copy from read-only mount
          ├── <pre-build command>        ← optional (e.g. web UI compilation)
          ├── shards install
          ├── shards build --release --static
          └── cp bin/<name> /output      ← write to host via mount
```

The project directory is mounted **read-only** into the container. A writable
workspace is created by copying it, so the build can write to `lib/` and `bin/`
freely without touching the host source tree. Only the output binary is written
back to the host, via a separate writable mount.

## Architecture

The script builds **natively** for whatever CPU architecture the host machine
is running — amd64 or arm64. It does not cross-compile or use emulation.
Podman and Docker both pull the image matching the host's native architecture
automatically, so the build is fast and produces a binary for that
architecture only.

```
Apple Silicon Mac  ──► arm64 binary
Intel Mac           ──► amd64 binary
ARM Linux host       ──► arm64 binary
x86_64 Linux host    ──► amd64 binary
```

Output filenames include the architecture to avoid collisions:
`bin/release/<name>-linux-amd64`, `bin/release/<name>-linux-arm64`.

**To produce both architectures**, run the script on a runner of each kind
— this is the recommended approach in CI, mirroring the existing macOS matrix
(`macos-latest` for arm64, `macos-15-intel` for x86_64). GitHub Actions
provides native ARM Linux runners (`ubuntu-24.04-arm` and similar), so no
QEMU or cross-compilation is needed:

```yaml
strategy:
  matrix:
    include:
      - runner: ubuntu-latest
        arch: amd64
      - runner: ubuntu-24.04-arm
        arch: arm64
runs-on: ${{ matrix.runner }}
```

Each runner builds its own native binary; the script's automatic architecture
detection means no extra flags are needed per matrix entry.

## Prerequisites

Either [Podman](https://podman.io) or [Docker](https://docker.com) must be
installed. Podman is preferred — it is daemonless and runs rootless by default,
which is safer on developer machines and in CI. Both are fully supported and
the script auto-detects whichever is available.

To verify a build locally using an Ubuntu container (as the script does
not require the host to run Linux):

```sh
podman run -it --rm \
  -e TERM="$TERM" -e LANG="$LANG" \
  -v ./bin:/data/bin \
  ubuntu /bin/bash

# Inside the container:
/data/bin/linux/myapp
```

## Usage

```sh
# Basic build
bin/crystal-linux-static-build src/myapp.cr

# With sqlite3 (e.g. crystal-sqlite3 shard or vecstolite)
bin/crystal-linux-static-build src/myapp.cr \
  --extra-apks "sqlite-static"

# With a web UI pre-build step
bin/crystal-linux-static-build src/enkaidu.cr \
  --binary enkaidu \
  --extra-apks "nodejs npm sqlite-static" \
  --pre-build "cd webui && npm i && npm run build && cd .."

# Use docker explicitly instead of podman
bin/crystal-linux-static-build src/myapp.cr --engine docker

# Full options
bin/crystal-linux-static-build --help
```

The output binary lands at `bin/release/<name>-linux-<arch>` by default, where
`<arch>` is `amd64` or `arm64` based on the host. This distinguishes both
architectures and the native macOS build from each other in the same
directory.

## Alpine APK reference

The `crystallang/crystal:latest-alpine` image already includes Crystal's own
runtime dependencies (`libgc`, `libevent`, `pcre2`). You only need to add
packages for C libraries your shards require directly.

|Library|APK package(s)                   |
|-------|---------------------------------|
|sqlite3|`sqlite-static`                  |
|OpenSSL|`openssl-dev openssl-libs-static`|
|libxml2|`libxml2-dev libxml2-static`     |
|libyaml|`yaml-dev yaml-static`           |

Find packages at [pkgs.alpinelinux.org](https://pkgs.alpinelinux.org/packages).
Filter by `edge` or the current Alpine version and look for `-static` variants
for any C library you need.

## In a GitHub Actions release workflow

The script works in CI as-is, provided the runner has podman or docker
available. Ubuntu runners have docker pre-installed. To build both
architectures, use a matrix with native amd64 and arm64 runners:

```yaml
jobs:
  release-linux:
    strategy:
      matrix:
        include:
          - runner: ubuntu-latest
            arch: amd64
          - runner: ubuntu-24.04-arm
            arch: arm64
    runs-on: ${{ matrix.runner }}
    steps:
      - name: Checkout with submodules
        uses: actions/checkout@v6
        with:
          submodules: true

      - name: Build static Linux binary
        run: |
          tools/crystal-build-tools/bin/crystal-linux-static-build src/myapp.cr \
            --binary myapp \
            --extra-apks "sqlite-static" \
            --engine docker
```

The script auto-detects the architecture from the runner, so the same command
works unchanged on both matrix entries — output files won't collide since the
architecture is included in the filename.

Alternatively, for Linux release builds you can use the
`crystallang/crystal:latest-alpine` container image directly as the runner,
which gives you a native Alpine environment and makes the script unnecessary:

```yaml
jobs:
  release-linux:
    runs-on: ubuntu-latest
    container:
      image: crystallang/crystal:latest-alpine
    steps:
      - uses: actions/checkout@v6
      - run: apk add --no-cache sqlite-static
      - run: shards build --release --static
```

The script is most useful for local development builds and for CI setups where
the container-as-runner approach isn't convenient.

## Relationship to `crystal-macos-static-build`

The two scripts solve different problems with different techniques:

|             |`crystal-linux-static-build` |`crystal-macos-static-build`  |
|-------------|-----------------------------|------------------------------|
|**Output**   |Linux ELF, fully static      |macOS Mach-O, partially static|
|**Technique**|Alpine container + `--static`|`--emit obj` + manual `cc`    |
|**Deps**     |podman or docker             |Homebrew                      |
|**Host OS**  |macOS or Linux               |macOS only                    |

See [`macos-static-linking.md`](macos-static-linking.md) for the full
account of why macOS requires a different approach.
