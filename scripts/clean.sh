#!/usr/bin/env bash
# Removes build output. By default only the out/ tree is wiped; pass --all
# to also drop the V8 checkout and depot_tools clone.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ALL=0
[[ "${1:-}" == --all ]] && ALL=1

if [[ -d "$V8_DIR/out" ]]; then
  log "removing $V8_DIR/out"
  rm -rf "$V8_DIR/out"
fi

if [[ -d "$DIST_DIR" ]]; then
  log "removing $DIST_DIR"
  rm -rf "$DIST_DIR"
fi

if [[ "$ALL" == 1 ]]; then
  log "removing $V8_DIR and $DEPOT_TOOLS_DIR"
  rm -rf "$V8_DIR" "$DEPOT_TOOLS_DIR"
fi
