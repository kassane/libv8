# libv8

Fully-automated builds of the V8 JavaScript engine as a static monolith
library (`libv8_monolith.a` / `v8_monolith.lib`) for multiple platforms.

Inspired by [`kuoruan/libv8`](https://github.com/kuoruan/libv8) and
[`just-js/v8`](https://github.com/just-js/v8); rewritten around a single
`scripts/` pipeline that is reproducible from your laptop and identical to CI.

## What you get

Per release, one archive per target × profile:

```
libv8-<version>-<os>-<arch>-<profile>.tar.xz   # linux, macos
libv8-<version>-<os>-<arch>-<profile>.zip      # windows
SHA256SUMS                                     # combined manifest
```

Archive layout:

```
include/                # V8 public headers
lib/libv8_monolith.a    # the static monolith (v8_monolith.lib on Windows)
gen/                    # generated headers (torque, inspector, ...)
args.gn                 # exact GN args used for this build
VERSION                 # V8 tag this artifact was cut from
```

Supported targets:

| OS      | Arch  | Runner                          | Status |
|---------|-------|---------------------------------|--------|
| Linux   | x64   | `ubuntu-22.04`                  | ✅ required |
| Linux   | arm64 | `ubuntu-22.04-arm`              | optional |
| macOS   | arm64 | `macos-latest`                  | optional |
| Windows | x64   | `windows-latest` (Server 2025)  | optional |
| Windows | arm64 | `windows-11-arm`                | optional |

Optional targets run with `continue-on-error`, so a failure on them doesn't
fail the workflow. Linux x64 is the only hard-required target.

Build profiles (see `args/profiles/`):

| Profile               | i18n | Pointer compression | Sandbox | Use case |
|-----------------------|------|---------------------|---------|----------|
| `default`             | off  | off                 | off     | smallest, most-portable embedding |
| `pointer-compression` | off  | on                  | off     | matches Node.js / Chrome layout   |
| `sandbox`             | off  | on                  | on      | hardened embedding                |
| `i18n`                | on   | off                 | off     | needs `Intl` / ICU                |

> Pointer compression and sandbox are ABI-affecting. Embedding code **must**
> be compiled with `-DV8_COMPRESS_POINTERS` (and `-DV8_ENABLE_SANDBOX` for
> the `sandbox` profile) matching the library it links against.

## Build locally

```bash
just fetch                                # clone depot_tools + sync V8
just build                                # host triple, default profile
just build linux-arm64 pointer-compression
just package linux-arm64 pointer-compression
just all macos-arm64                      # fetch + build + package
```

Scripts work standalone if you don't have `just`:

```bash
./scripts/fetch.sh
./scripts/build.sh linux-x64 default
./scripts/package.sh linux-x64 default
```

### Requirements

- Python 3.8+, `git`, ~25 GB disk
- A C++ toolchain (clang preferred; MSVC on Windows)
- Optional: `ccache` / `sccache` — auto-detected and wired into `args.gn`

## Bump the V8 version

```bash
echo '14.5.227.3' > VERSION
git commit -am 'chore: bump V8 to 14.5.227.3'
git tag v14.5.227.3
git push --follow-tags
```

The tag push triggers `release.yml` which builds every target × profile and
publishes a GitHub Release with archives + `SHA256SUMS`.

## Automated upstream tracking

`.github/workflows/version-check.yml` runs every Monday at 06:00 UTC.
It compares `./VERSION` against the latest V8 tag and, when newer:

1. commits the bump to `main`
2. pushes the matching `v<ver>` tag
3. which triggers `release.yml` → publishes the new release

> Optional: provide a `RELEASE_TOKEN` secret (PAT with `contents:write`) if
> `main` is protected against the default `GITHUB_TOKEN`.

## CI runner cost

macOS / Windows minutes are billed at 10× / 2× the Linux rate. The workflow
degrades gracefully:

- macOS and Windows matrix entries run with `continue-on-error`, so a billing
  block doesn't turn PRs red — Linux jobs still hard-fail on real regressions.
- `build.yml` accepts a `runners` input: `all` (default) or `free-only`
  (Linux x64 + arm64 only).

`release.yml` always uses `all` so published releases stay complete.

## Repository layout

```
.
├── VERSION                     # The pinned V8 tag (single source of truth)
├── .gclient                    # depot_tools solution with pruned deps
├── args/
│   ├── common.gn
│   ├── {linux,macos,windows}.{x64,arm64}.gn
│   └── profiles/{default,pointer-compression,sandbox,i18n}.gn
├── scripts/{lib,fetch,build,package,clean,check-version}.sh
├── Justfile
└── .github/
    ├── actions/setup-depot-tools/
    └── workflows/{build,release,version-check}.yml
```

## License

MIT. V8 is licensed under its own BSD-style terms (shipped inside each archive).
