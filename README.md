# libv8

V8 JavaScript engine built as a static monolith (`libv8_monolith.a` /
`v8_monolith.lib`) for Linux, macOS, and Windows.

## Releases

Each release ships one archive per target × profile, plus `SHA256SUMS`:

```
libv8-<version>-<os>-<arch>-<profile>.tar.xz   # linux, macos
libv8-<version>-<os>-<arch>-<profile>.zip      # windows
```

Inside:

```
include/                # public headers
lib/libv8_monolith.a    # static monolith (v8_monolith.lib on Windows)
gen/                    # generated headers (torque, inspector, ...)
args.gn                 # exact GN args used for this build
VERSION                 # V8 tag this artifact was cut from
```

### Targets

| OS      | Arch  | Runner             |
|---------|-------|--------------------|
| Linux   | x64   | `ubuntu-22.04`     |
| Linux   | arm64 | `ubuntu-22.04-arm` |
| macOS   | arm64 | `macos-latest`     |
| Windows | x64   | `windows-latest`   |
| Windows | arm64 | `windows-11-arm`   |

`linux-x64` is required; the rest are `continue-on-error` so a paid-runner
outage doesn't fail the workflow. `scripts/patch-v8.sh` carries the V8
14.9-specific source patches that the non-Linux targets need; each patch is
idempotent and sentinel-gated so a future V8 bump that ships the fix
upstream silently no-ops.

### Profiles

| Profile               | i18n | Pointer compression | Sandbox |
|-----------------------|------|---------------------|---------|
| `default`             | off  | off                 | off     |
| `pointer-compression` | off  | on                  | off     |
| `sandbox`             | off  | on                  | on      |
| `i18n`                | on   | off                 | off     |

Pointer compression and sandbox are ABI-affecting: embedding code must be
built with matching `-DV8_COMPRESS_POINTERS` / `-DV8_ENABLE_SANDBOX`.

## Build locally

```bash
just fetch                                # clone depot_tools + sync V8
just build                                # host triple, default profile
just build linux-arm64 pointer-compression
just all macos-arm64                      # fetch + build + package
```

Without `just`:

```bash
./scripts/fetch.sh
./scripts/build.sh linux-x64 default
./scripts/package.sh linux-x64 default
```

Requires Python 3.8+, `git`, a C++ toolchain, and ~25 GB free disk. `ccache`
/ `sccache` are auto-detected.

## Releases & version tracking

Releases are fully automated:

1. **Weekly cron** (`version-check.yml`, Mondays 06:00 UTC) compares `VERSION`
   against the latest upstream V8 tag.
2. If outdated, it opens a `chore: bump V8 to <ver>` PR with auto-merge
   enabled.
3. PR CI runs the full matrix on the proposed version. Only a green PR
   merges — a broken upstream is caught before it touches `main`.
4. `auto-tag.yml` watches for `VERSION`-changing pushes to `main` and
   pushes the matching `v<ver>` tag, which triggers `release.yml` to
   build and publish.

Manual bump: edit `VERSION`, merge → tag is created automatically.

Manual dispatch of `version-check.yml` accepts a `force: true` input to
open the PR even when `VERSION` is current (useful for re-rolling a release).

### Prerequisites

- Repo setting **Allow auto-merge** must be on.
- Optional: set a `RELEASE_TOKEN` secret (PAT with `contents:write`,
  `pull-requests:write`) if branch protection blocks `GITHUB_TOKEN`.

## CI runner cost

macOS/Windows minutes bill at 10×/2× Linux. `build.yml` accepts
`runners: free-only` (Linux x64 + arm64) for cheap iteration; `release.yml`
always uses `all`.

## Repository layout

```
VERSION                # pinned V8 tag (single source of truth)
.gclient               # depot_tools solution with pruned deps
args/                  # GN args per target + profile
scripts/               # fetch / build / package / patch / version pipeline
Justfile
.github/
  actions/setup-depot-tools/
  workflows/{build,release,version-check,auto-tag}.yml
```

## Credits

Inspired by [`kuoruan/libv8`](https://github.com/kuoruan/libv8) and
[`just-js/v8`](https://github.com/just-js/v8).

## License

MIT. V8 ships under its own BSD-style terms (included in each archive).
