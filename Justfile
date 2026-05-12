# Ergonomic entrypoints for the libv8 build pipeline.
# Run `just` (no args) to list targets.

target  := env_var_or_default('TARGET', '')
profile := env_var_or_default('PROFILE', 'default')

default:
    @just --list

# Clone depot_tools (if needed) and sync the V8 tree pinned in ./VERSION.
fetch:
    ./scripts/fetch.sh

# Build libv8_monolith for [target] [profile] (defaults: host triple / default).
build target=target profile=profile:
    ./scripts/build.sh {{target}} {{profile}}

# Package the previously-built target into a portable archive under ./dist/.
package target=target profile=profile:
    ./scripts/package.sh {{target}} {{profile}}

# Full pipeline for one target: fetch -> build -> package.
all target=target profile=profile: fetch (build target profile) (package target profile)

# Build every supported target for the current host OS (where possible).
all-host:
    #!/usr/bin/env bash
    set -euo pipefail
    just fetch
    case "$(uname -s)" in
      Linux*)  for t in linux-x64 linux-arm64; do just all "$t"; done ;;
      Darwin*) for t in macos-x64 macos-arm64; do just all "$t"; done ;;
      MINGW*|MSYS*|CYGWIN*) for t in windows-x64 windows-arm64; do just all "$t"; done ;;
      *) echo "unsupported host"; exit 1 ;;
    esac

# Wipe build outputs. Use `just clean-all` to also drop the V8 checkout.
clean:
    ./scripts/clean.sh

clean-all:
    ./scripts/clean.sh --all

# Compare ./VERSION against the latest upstream V8 tag.
check-version:
    ./scripts/check-version.sh
