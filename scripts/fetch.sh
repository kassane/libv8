#!/usr/bin/env bash
# Fetches (or refreshes) the V8 source tree pinned to ./VERSION.
#
# Usage: scripts/fetch.sh
#
# Idempotent: safe to re-run; it only fast-forwards / re-syncs gclient deps.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ensure_depot_tools

# .gclient lives at the repo root; gclient looks for it in $PWD.
cd "$ROOT_DIR"

if [[ ! -d "$V8_DIR/.git" ]]; then
  log "fresh checkout (no existing v8/.git)"
  rm -rf "$V8_DIR"
  git clone --no-checkout https://chromium.googlesource.com/v8/v8.git "$V8_DIR"
fi

log "checking out V8 $V8_VERSION"
git -C "$V8_DIR" fetch --depth=1 origin "refs/tags/$V8_VERSION:refs/tags/$V8_VERSION" \
  || git -C "$V8_DIR" fetch origin
git -C "$V8_DIR" checkout --detach "$V8_VERSION"

log "gclient sync (this will take a while on first run)"
gclient sync --no-history --reset --jobs="$(nproc_portable)"

log "V8 $V8_VERSION ready in $V8_DIR"
