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

log "resolving V8 ref: $V8_VERSION"
# V8 ships both release tags (e.g. 14.9.207.4) and branch refs
# (e.g. branch-heads/14.9). Try the tag first, then the branch head.
if git -C "$V8_DIR" fetch --depth=1 origin \
     "refs/tags/$V8_VERSION:refs/tags/$V8_VERSION" 2>/dev/null; then
  CHECKOUT_REF="$V8_VERSION"
elif git -C "$V8_DIR" fetch --depth=1 origin \
       "refs/branch-heads/$V8_VERSION" 2>/dev/null; then
  CHECKOUT_REF=FETCH_HEAD
else
  die "V8 ref '$V8_VERSION' not found upstream (not a tag, not a branch-head). \
Check https://chromium.googlesource.com/v8/v8/+refs for valid refs."
fi
git -C "$V8_DIR" checkout --detach "$CHECKOUT_REF"

log "gclient sync (this will take a while on first run)"
gclient sync --no-history --reset --jobs="$(nproc_portable)"

log "V8 $V8_VERSION ready in $V8_DIR"
