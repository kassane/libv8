# libv8

Fully-automated builds of the V8 JavaScript engine as a static monolith
library (`libv8_monolith.a` / `v8_monolith.lib`) for multiple platforms.

Inspired by [`kuoruan/libv8`](https://github.com/kuoruan/libv8) and
[`just-js/v8`](https://github.com/just-js/v8); rewritten around a single
`scripts/` pipeline that is reproducible from your laptop and identical to CI.

## What you get

Each release ships these archives (per target × profile):

```
libv8-<version>-<os>-<arch>-<profile>.tar.xz   # linux, macos
libv8-<version>-<os>-<arch>-<profile>.zip      # windows
libv8-<version>-<os>-<arch>-<profile>.sha256
SHA256SUMS                                     # combined manifest
```

Archive layout:

```
include/                # V8 public headers (v8.h, v8-*.h, cppgc/, libplatform/)
lib/libv8_monolith.a    # the static monolith
gen/                    # generated headers (torque, inspector, ...)
args.gn                 # exact GN args used for this build
VERSION                 # V8 tag this artifact was cut from
```

Supported targets:

| OS      | Arch     | Notes                                          |
|---------|----------|------------------------------------------------|
| Linux   | x64      | `ubuntu-22.04` runner                          |
| Linux   | arm64    | `ubuntu-22.04-arm` runner                      |
| macOS   | x64      | `macos-13` (Xcode default SDK)                 |
| macOS   | arm64    | `macos-latest` (Apple Silicon, Xcode default SDK) |
| Windows | x64      | `windows-latest` (Server 2025), system MSVC, no Google toolchain |
| Windows | arm64    | `windows-11-arm` (native ARM64 partner runner) |

Supported build profiles (see `args/profiles/`):

| Profile               | i18n | Pointer compression | Sandbox | Use case |
|-----------------------|------|---------------------|---------|----------|
| `default`             | off  | off                 | off     | smallest, most-portable embedding |
| `pointer-compression` | off  | on                  | off     | matches Node.js / Chrome layout   |
| `sandbox`             | off  | on                  | on      | hardened embedding                |
| `i18n`                | on   | off                 | off     | needs `Intl` / ICU                |

> **Note** Pointer compression and sandbox are ABI-affecting. Your embedding
> code **must** be compiled with the same flag as the library it links.

## Build locally

```bash
# One-time
git clone https://github.com/kassane/libv8 && cd libv8

# Fetch V8 (clones depot_tools the first time)
just fetch          # or:  make fetch

# Build for the host triple, default profile
just build          # or:  make build

# Build a specific target / profile
just build linux-arm64 pointer-compression
make build TARGET=macos-arm64 PROFILE=sandbox

# Package into ./dist/
just package linux-arm64 pointer-compression

# Full pipeline (fetch + build + package)
just all macos-arm64
```

If you have neither `just` nor `make` installed, the scripts work standalone:

```bash
./scripts/fetch.sh
./scripts/build.sh linux-x64 default
./scripts/package.sh linux-x64 default
```

### Requirements

- Python 3.8+
- `git`
- ~25 GB free disk space for the V8 checkout + build
- A C++ toolchain (clang preferred; MSVC on Windows)
- Optional: `ccache` (Linux/macOS) or `sccache` (Windows) — auto-detected

## Bump the V8 version

```bash
echo '14.5.227.3' > VERSION
git commit -am 'chore: bump V8 to 14.5.227.3'
git tag v14.5.227.3
git push --follow-tags
```

The tag push triggers `.github/workflows/release.yml`, which rebuilds every
target × profile and publishes a GitHub Release with attached archives and
`SHA256SUMS`.

## Automated upstream tracking

`.github/workflows/version-check.yml` runs every Monday at 06:00 UTC.
It compares `./VERSION` against the latest V8 tag from upstream
[`v8/v8.git`](https://chromium.googlesource.com/v8/v8.git) and, when it
finds something newer:

1. commits the bump to `main` (`chore: bump V8 to <ver>`)
2. pushes the matching `v<ver>` tag
3. which triggers `release.yml`
4. which publishes the new release

No human action required — set the workflow loose and forget about it.

> **Optional** Provide a `RELEASE_TOKEN` repo secret (a PAT with `contents:write`)
> if you protect `main` against the default `GITHUB_TOKEN`. Otherwise the
> default token is used.

## CI runner cost

GitHub bills macOS and Windows minutes at 10× and 2× the Linux rate respectively.
This repo handles that two ways:

- The macOS and Windows matrix entries are marked `optional: true` and run with
  `continue-on-error`, so a paid-runner billing block (or outage) will not turn
  a PR red — Linux jobs still hard-fail on real regressions.
- `build.yml` (manual run / `workflow_call`) accepts a `runners` input:
  - `all` (default) — Linux + macOS + Windows
  - `free-only` — Linux x64 + Linux arm64 only

`release.yml` always uses `runners: all` so published releases include every
platform. If a billing block prevents that, fix the billing and re-run the
release workflow from the Actions tab.

## Repository layout

```
.
├── VERSION                     # The pinned V8 tag (single source of truth)
├── .gclient                    # depot_tools solution with pruned deps
├── args/
│   ├── common.gn               # Shared base args
│   ├── {linux,macos,windows}.{x64,arm64}.gn
│   └── profiles/{default,pointer-compression,sandbox,i18n}.gn
├── scripts/
│   ├── lib.sh                  # Shared helpers (target parsing, depot_tools, etc.)
│   ├── fetch.sh                # gclient sync wrapper
│   ├── build.sh                # gn gen + ninja v8_monolith
│   ├── package.sh              # tarball/zip + sha256
│   ├── clean.sh                # remove build / checkout
│   └── check-version.sh        # compare ./VERSION to upstream tags
├── Justfile                    # `just` entrypoints
├── Makefile                    # `make` entrypoints (same surface)
└── .github/
    ├── actions/setup-depot-tools/   # composite action used by build.yml
    └── workflows/
        ├── build.yml           # matrix build, also reusable via workflow_call
        ├── release.yml         # tag-triggered release
        └── version-check.yml   # weekly upstream sync + auto-release
```

## Consuming the artifacts

```cmake
# CMake example
set(LIBV8_DIR "${CMAKE_SOURCE_DIR}/third_party/libv8")
add_library(v8_monolith STATIC IMPORTED)
set_target_properties(v8_monolith PROPERTIES
  IMPORTED_LOCATION   "${LIBV8_DIR}/lib/libv8_monolith.a"
  INTERFACE_INCLUDE_DIRECTORIES "${LIBV8_DIR}/include"
)
target_link_libraries(my_app PRIVATE v8_monolith pthread dl)
```

Compiler flags you'll typically need:

- `-DV8_COMPRESS_POINTERS` when using the `pointer-compression` or `sandbox` profile
- `-DV8_ENABLE_SANDBOX` when using the `sandbox` profile
- `-std=c++20`

## License

MIT. V8 itself is licensed under the BSD-style license shipped inside each
archive (see `gen/` and the V8 upstream `LICENSE.v8`).
