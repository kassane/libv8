#!/usr/bin/env bash
# Packages a built libv8_monolith into a portable archive under ./dist/.
#
# Usage: scripts/package.sh [target] [profile]
#
# Produces:
#   dist/libv8-<version>-<target>-<profile>.tar.xz   (linux, macos)
#   dist/libv8-<version>-<target>-<profile>.zip      (windows)
#   dist/libv8-<version>-<target>-<profile>.sha256
#
# Archive layout:
#   include/             -> v8 public headers
#   lib/libv8_monolith.a (or v8_monolith.lib on Windows)
#   gen/                 -> generated headers/torque outputs (needed at compile time)
#   args.gn              -> effective args used for this build
#   VERSION              -> the V8 tag
set -euo pipefail
source "$(dirname "$0")/lib.sh"

parse_target "${1:-}"
PROFILE="${2:-default}"
OUT_NAME="${OUT_NAME:-$TARGET.$PROFILE}"
OUT_DIR="$V8_DIR/out/$OUT_NAME"

LIB_NAME="libv8_monolith.a"
[[ "$TARGET_OS" == windows ]] && LIB_NAME="v8_monolith.lib"
LIB_PATH="$OUT_DIR/obj/$LIB_NAME"
[[ -f "$LIB_PATH" ]] || die "missing built lib at $LIB_PATH (did the build succeed?)"

mkdir -p "$DIST_DIR"

STAGE="$DIST_DIR/.stage/libv8-$V8_VERSION-$TARGET-$PROFILE"
rm -rf "$STAGE"
mkdir -p "$STAGE/include" "$STAGE/lib" "$STAGE/gen"

log "staging headers"
cp -R "$V8_DIR/include/." "$STAGE/include/"

log "staging library"
cp "$LIB_PATH" "$STAGE/lib/"

# i18n builds produce an icudtl.dat sidecar next to the binary. The
# static-lib monolith doesn't load it on its own; the embedder must
# call V8::InitializeICUDefaultLocation(path_to_icudtl) before
# V8::Initialize, otherwise Intl.* and \p{…} unicode-property regex
# throw at first use. Colocated with the static lib under lib/ so the
# embedder can reference one well-known path inside the archive. Only
# present for the `i18n` profile (other profiles don't produce it).
if [[ -f "$OUT_DIR/icudtl.dat" ]]; then
  log "staging icudtl.dat"
  cp "$OUT_DIR/icudtl.dat" "$STAGE/lib/icudtl.dat"
fi

if [[ -d "$OUT_DIR/gen" ]]; then
  log "staging generated headers"
  # Only the public-ish bits embedders typically need; pull the full gen tree
  # — it is small enough and avoids guessing which files belong.
  cp -R "$OUT_DIR/gen/." "$STAGE/gen/"
fi

cp "$OUT_DIR/args.gn" "$STAGE/args.gn"
echo "$V8_VERSION" > "$STAGE/VERSION"

ARCHIVE_BASE="libv8-$V8_VERSION-$TARGET-$PROFILE"
cd "$DIST_DIR/.stage"
if [[ "$TARGET_OS" == windows ]]; then
  ARCHIVE="$DIST_DIR/$ARCHIVE_BASE.zip"
  rm -f "$ARCHIVE"
  if command -v 7z >/dev/null 2>&1; then
    7z a -tzip "$ARCHIVE" "$ARCHIVE_BASE" >/dev/null
  else
    ( cd "$ARCHIVE_BASE" && zip -qr "$ARCHIVE" . )
  fi
else
  ARCHIVE="$DIST_DIR/$ARCHIVE_BASE.tar.xz"
  rm -f "$ARCHIVE"
  XZ_OPT="${XZ_OPT:--T0 -9}" tar -cJf "$ARCHIVE" "$ARCHIVE_BASE"
fi

cd "$DIST_DIR"
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$(basename "$ARCHIVE")" > "$ARCHIVE_BASE.sha256"
else
  sha256sum "$(basename "$ARCHIVE")" > "$ARCHIVE_BASE.sha256"
fi

log "packaged $ARCHIVE"
log "checksum:"
cat "$DIST_DIR/$ARCHIVE_BASE.sha256" >&2
