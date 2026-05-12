#!/usr/bin/env bash
# Reports whether the V8 tag pinned in ./VERSION is the latest stable.
# Used by the version-check workflow to open a PR when V8 cuts a new release.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

LATEST="$(git ls-remote --tags --refs https://chromium.googlesource.com/v8/v8.git \
  | awk -F'refs/tags/' '{print $2}' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -V \
  | tail -n1)"

[[ -n "$LATEST" ]] || die "could not list V8 tags"

echo "current: $V8_VERSION"
echo "latest:  $LATEST"

if [[ "$V8_VERSION" != "$LATEST" ]]; then
  echo "::set-output name=outdated::true" 2>/dev/null || true
  echo "outdated=true"   >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
  echo "latest=$LATEST"  >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
  echo "current=$V8_VERSION" >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
  exit 0
fi

echo "up to date"
echo "outdated=false" >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
