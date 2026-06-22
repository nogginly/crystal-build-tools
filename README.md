# Crystal build tools

A collection of scripts for building and distributing [Crystal](https://crystal-lang.org)
applications, with a focus on producing self-contained binaries for release.

## Install via git submodule

```sh
git submodule add https://github.com/nogginly/crystal-build-tools tools/crystal-build-tools
```

## Scripts

### `crystal-macos-static-build`

Builds a Crystal binary on macOS with all third-party libraries linked
statically, so the result only depends on Apple's own system libraries
(`libSystem`, `libiconv`). This makes the binary distributable to any Mac
without requiring Homebrew or a Crystal installation.

```sh
# Basic build — auto-discovers Crystal's deps
bin/crystal-macos-static-build src/myapp.cr -o bin/release/myapp

# With additional libs (e.g. openssl, sqlite)
bin/crystal-macos-static-build src/myapp.cr -o bin/release/myapp \
  -l ssl -l crypto -l xml2 -l yaml -l sqlite3

# Full options
bin/crystal-macos-static-build --help
```

> On Linux, use Crystal's own `--static` flag instead (works out of the box on
> Alpine), or use `crystal-linux-static-build` below to produce a Linux binary
> from macOS. See [`docs/macos-static-linking.md`](docs/macos-static-linking.md)
> for why a separate tool is needed on macOS specifically.

#### Manual usage

```sh
tools/crystal-build-tools/bin/crystal-macos-static-build src/myapp.cr \
  -o bin/release/myapp --release
```

#### GitHub Actions workflow usage

```yaml
- name: Checkout with submodules
  uses: actions/checkout@v6
  with:
    submodules: true

- name: Build release binary
  run: |
    tools/crystal-build-tools/bin/crystal-macos-static-build src/myapp.cr \
      -o bin/release/myapp --release
```

### `crystal-linux-static-build`

Builds a fully static Crystal binary for Linux using an Alpine container, from
either macOS or Linux. The result has zero runtime dependencies and runs on
any Linux of the matching architecture. Supports both Podman and Docker.

```sh
# Basic build — fully static binary for Linux
bin/crystal-linux-static-build src/myapp.cr

# With sqlite3 (e.g. crystal-sqlite3 shard or vecstolite)
bin/crystal-linux-static-build src/myapp.cr \
  --extra-apks "sqlite-static"

# With a web UI pre-build step
bin/crystal-linux-static-build src/enkaidu.cr \
  --binary enkaidu \
  --extra-apks "nodejs npm sqlite-static" \
  --pre-build "cd webui && npm i && npm run build && cd .."

# Full options
bin/crystal-linux-static-build --help
```

> Podman is preferred when both are available (daemonless, rootless by
> default); pass `--engine docker` to use Docker instead.

#### Manual usage

```sh
tools/crystal-build-tools/bin/crystal-linux-static-build src/myapp.cr \
  --binary myapp --extra-apks "sqlite-static"
```

#### GitHub Actions workflow usage

```yaml
- name: Checkout with submodules
  uses: actions/checkout@v6
  with:
    submodules: true

- name: Build static Linux binary
  run: |
    tools/crystal-build-tools/bin/crystal-linux-static-build src/myapp.cr \
      --binary myapp --extra-apks "sqlite-static" --engine docker
```

## Development

Each script is self-documented: `--help` prints the header comment block, so
keep that up to date when changing behaviour or adding options.

### Running the tests

Integration tests run the scripts against minimal Crystal fixture projects
in `test/fixtures/` and verify the output.

```sh
# macOS — requires Crystal and Homebrew static libs
brew install bdw-gc libevent pcre2 openssl@3 libxml2 libyaml sqlite
chmod +x bin/*.sh test/*.sh
test/test-macos.sh

# Linux — requires podman or docker
chmod +x bin/*.sh test/*.sh
test/test-linux.sh

# Verbose output (shows all script commands)
VERBOSE=1 test/test-macos.sh
VERBOSE=1 test/test-linux.sh
```

CI runs these automatically on push and pull request, across all four
supported runner configurations (macOS arm64, macOS x86_64, Linux amd64,
Linux arm64).

### Why?

The background and reasoning behind these tools is documented in:

- [`docs/macos-static-linking.md`](docs/macos-static-linking.md) — the
  investigation behind `crystal-macos-static-build`: what was tried, what
  failed, and why a manual link step is necessary on macOS.
- [`docs/linux-static-building.md`](docs/linux-static-building.md) — the
  approach behind `crystal-linux-static-build`, the Alpine APK reference, and
  how the two scripts relate.

## Contributions, by invitation!

*With apologies*, at this time contributions are *by invitation only* and limited to people I know and see often.

These are early days for _Sandboxer_ and I am busy with family and work.

At this time I want to work on this at a manageable pace.
