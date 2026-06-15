# Crystal build tools

A collection of scripts for building and distributing [Crystal](https://crystal-lang.org)
applications, with a focus on producing self-contained binaries for release.

## Install via git submodule

```sh
git submodule add https://github.com/enkaidu-dev/crystal-build-tools tools/crystal-build-tools
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
> Alpine). See [`docs/macos-static-linking.md`](docs/macos-static-linking.md)
> for why a separate tool is needed on macOS.

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

### Why?

The background and reasoning behind these tools is documented in
[`docs/macos-static-linking.md`](docs/macos-static-linking.md) — a full
account of what was tried, what failed, and why the current approach works.

## Contributions, by invitation!

*With apologies*, at this time contributions are *by invitation only* and limited to people I know and see often.

These are early days for _Sandboxer_ and I am busy with family and work.

At this time I want to work on this at a manageable pace.
