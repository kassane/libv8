#!/usr/bin/env bash
# Shared helpers sourced by every script in this directory.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPOT_TOOLS_DIR="${DEPOT_TOOLS_DIR:-$ROOT_DIR/.depot_tools}"
V8_DIR="${V8_DIR:-$ROOT_DIR/v8}"
OUT_NAME="${OUT_NAME:-release}"
OUT_DIR="${OUT_DIR:-$V8_DIR/out/$OUT_NAME}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"

V8_VERSION="$(head -n1 "$ROOT_DIR/VERSION" | tr -d '[:space:]')"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

# Host OS slug used by detect_target / args filenames.
detect_os() {
  case "$(uname -s)" in
    Linux*)   echo linux ;;
    Darwin*)  echo macos ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) die "unsupported host OS: $(uname -s)" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x64 ;;
    arm64|aarch64) echo arm64 ;;
    *) die "unsupported host arch: $(uname -m)" ;;
  esac
}

# Parse a TARGET string ("linux-x64", "macos-arm64", ...) into OS / ARCH.
# Defaults to the host triple when called with an empty argument.
parse_target() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    target="$(detect_os)-$(detect_arch)"
  fi
  TARGET_OS="${target%-*}"
  TARGET_ARCH="${target##*-}"
  case "$TARGET_OS" in linux|macos|windows) ;; *) die "bad target os: $TARGET_OS" ;; esac
  case "$TARGET_ARCH" in x64|arm64) ;; *) die "bad target arch: $TARGET_ARCH" ;; esac
  TARGET="$TARGET_OS-$TARGET_ARCH"
}

# Prepend depot_tools to PATH (clones it on first use).
ensure_depot_tools() {
  if [[ ! -d "$DEPOT_TOOLS_DIR" ]]; then
    log "cloning depot_tools into $DEPOT_TOOLS_DIR"
    git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git \
      "$DEPOT_TOOLS_DIR"
  fi
  export PATH="$DEPOT_TOOLS_DIR:$PATH"
  export DEPOT_TOOLS_UPDATE="${DEPOT_TOOLS_UPDATE:-1}"
  if [[ "$(detect_os)" == windows ]]; then
    export DEPOT_TOOLS_WIN_TOOLCHAIN="${DEPOT_TOOLS_WIN_TOOLCHAIN:-0}"
  fi
}

# Compose effective args.gn from common + target + profile fragments.
# Writes the final content to stdout.
compose_args() {
  local target="$1" profile="${2:-default}"
  local common="$ROOT_DIR/args/common.gn"
  local target_file="$ROOT_DIR/args/${target/-/.}.gn"
  local profile_file="$ROOT_DIR/args/profiles/${profile}.gn"
  [[ -f "$common"       ]] || die "missing $common"
  [[ -f "$target_file"  ]] || die "no args for target $target ($target_file)"
  [[ -f "$profile_file" ]] || die "unknown profile '$profile' ($profile_file)"
  {
    echo "# --- args/common.gn ---"
    cat "$common"
    echo
    echo "# --- args/${target/-/.}.gn ---"
    cat "$target_file"
    echo
    echo "# --- args/profiles/${profile}.gn ---"
    cat "$profile_file"
  }
}

nproc_portable() {
  if command -v nproc >/dev/null 2>&1; then nproc
  elif [[ "$(uname -s)" == Darwin ]]; then sysctl -n hw.logicalcpu
  else echo 4
  fi
}
