#!/usr/bin/env bash
# Fetches (or refreshes) the V8 source tree pinned to ./VERSION using
# depot_tools/gclient. Idempotent: safe to re-run.
#
# Mirrors the flow proven in kuoruan/libv8:
#   1. clone V8 into ./v8 if it isn't already there
#   2. gclient sync --no-history --reset -r <ref> from $ROOT_DIR
#      (so it picks up the local .gclient with pruned deps)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ensure_depot_tools

cd "$ROOT_DIR"

if [[ ! -d "$V8_DIR/.git" ]]; then
  log "fresh checkout (no existing v8/.git)"
  rm -rf "$V8_DIR"
  git clone https://chromium.googlesource.com/v8/v8.git "$V8_DIR"
fi

log "gclient sync to V8 $V8_VERSION (this will take a while on first run)"
gclient sync --no-history --reset -r "$V8_VERSION" \
  --jobs="$(nproc_portable)"

log "V8 $(git -C "$V8_DIR" describe --tags --always) ready in $V8_DIR"
