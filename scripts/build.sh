#!/usr/bin/env bash
# Builds libv8_monolith for a TARGET / PROFILE combination.
#
# Usage: scripts/build.sh [target] [profile]
#   target  = <os>-<arch>, e.g. linux-x64, macos-arm64, windows-x64
#             (defaults to the host triple)
#   profile = default | pointer-compression | sandbox | i18n
#             (defaults to "default")
#
# Env overrides: V8_DIR, OUT_NAME, CC_WRAPPER (ccache/sccache), NINJA_JOBS.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

parse_target "${1:-}"
PROFILE="${2:-default}"
OUT_NAME="${OUT_NAME:-$TARGET.$PROFILE}"
OUT_DIR="$V8_DIR/out/$OUT_NAME"

[[ -d "$V8_DIR" ]] || die "V8 tree not found at $V8_DIR. Run scripts/fetch.sh first."

ensure_depot_tools

mkdir -p "$OUT_DIR"
ARGS_FILE="$OUT_DIR/args.gn"
compose_args "$TARGET" "$PROFILE" > "$ARGS_FILE"

: "${CC_WRAPPER:=$(command -v sccache 2>/dev/null || command -v ccache 2>/dev/null || true)}"
[[ -n "$CC_WRAPPER" ]] && printf '\ncc_wrapper = "%s"\n' "$(basename "$CC_WRAPPER")" >> "$ARGS_FILE"

log "effective args.gn:"
sed 's/^/    /' "$ARGS_FILE" >&2

log "gn gen $OUT_DIR"
( cd "$V8_DIR" && gn gen "out/$OUT_NAME" )

NINJA_JOBS="${NINJA_JOBS:-$(nproc_portable)}"
log "ninja -C out/$OUT_NAME v8_monolith (jobs=$NINJA_JOBS)"
( cd "$V8_DIR" && ninja -C "out/$OUT_NAME" -j "$NINJA_JOBS" v8_monolith )

# Surface the resolved args (useful for debugging upstream changes).
( cd "$V8_DIR" && gn args "out/$OUT_NAME" --list --short > "$OUT_DIR/args.resolved.txt" ) || true

log "built libv8_monolith for $TARGET ($PROFILE) in $OUT_DIR"
