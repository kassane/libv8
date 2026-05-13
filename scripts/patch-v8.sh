#!/usr/bin/env bash
# Apply surgical post-fetch patches to the V8 source tree to unblock V8
# 14.9 issues documented in PR #2. Each patch is idempotent: re-running
# is a no-op, and a future V8 bump that drops the underlying bug will
# cause the patch to silently skip.
#
# Patches:
#   1. src/base/macros.h — define a __has_warning(x)=0 shim on non-clang
#      so gcc-on-arm64 can preprocess the existing
#      `#if defined(__clang__) && defined(__has_warning) && \
#           __has_warning("...")`
#      guards (the third operand still triggers a parse error on gcc
#      even though the LHS short-circuits, because the preprocessor must
#      tokenise the whole expression before evaluating).
#   2. build/vs_toolchain.py — neutralise _CopyDebugger so a missing
#      host-x64 Debugging Tools subset on the windows-11-arm runner does
#      not abort the build. The static monolith doesn't load these DLLs.
#   3. src/objects/js-atomics-synchronization.h — alignas(uint64_t) on
#      JSSynchronizationPrimitive so MSVC honours the tagged-size class
#      alignment Torque assumes. Without it, V8_OBJECT's pack(4) caps
#      class alignment at 4 on MSVC (gcc/clang honour alignas inside
#      pack), making sizeof = 36 instead of Torque's 40 and triggering
#      Torque/C++ offset static_asserts on JSAtomicsMutex::owner_thread_id_
#      and JSAtomicsCondition::optional_padding_ for windows-x64.
#
# When a patch's needle doesn't match (upstream changed), the patch is
# skipped with a warning rather than killing the script — being too
# strict here would abort fetch.sh and leave no diagnostic.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ -d "$V8_DIR" ]] || die "v8 source not found at $V8_DIR (run fetch.sh first)"

run_py_patch() {
  local name="$1" file="$2" sentinel="$3"
  shift 3
  if [[ ! -f "$file" ]]; then
    warn "patch '$name': $file not found — skipping"
    return 0
  fi
  if grep -qF "$sentinel" "$file"; then
    log "patch '$name': already applied"
    return 0
  fi
  log "patch '$name': applying"
  if ! python3 - "$file" "$@"; then
    warn "patch '$name': python edit failed (upstream may have changed)"
    return 0
  fi
  if ! grep -qF "$sentinel" "$file"; then
    warn "patch '$name': sentinel not present after edit — patch silently skipped"
  fi
}

# ----------------------------------------------------------------------------
# Patch 1: src/base/macros.h — __has_warning shim for non-clang.
#
# V8 14.9 already guards __has_warning with `defined(__clang__) &&
# defined(__has_warning) && __has_warning(...)`. The guard fails on gcc
# anyway: the preprocessor must tokenise + parse the full #if expression
# before evaluating, and `__has_warning` (an unknown identifier in #if
# context on gcc) is replaced with the pp-number 0. The expression
# `0("-Wlifetime-safety")` is a syntax error ("missing binary operator
# before token (").
#
# Defining __has_warning as a function-like macro that returns 0 on
# non-clang lets the preprocessor expand it cleanly before the existing
# guard short-circuits the &&-chain.
run_py_patch \
  "macros.h __has_warning shim" \
  "$V8_DIR/src/base/macros.h" \
  "// libv8: __has_warning shim" <<'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
anchor = "// Disable/enable -Wlifetime-safety warnings in code."
if anchor not in src:
    sys.exit(f"macros.h: anchor not found: {anchor!r}")
shim = (
    "// libv8: __has_warning shim. gcc parses #if expressions in full\n"
    "// before short-circuiting && operators, so the existing guards on\n"
    "// __clang__ aren't enough — __has_warning is an unknown identifier\n"
    "// on gcc, replaced with the pp-number 0, leaving the parse error\n"
    "// 0(\"-Wlifetime-safety\"). Define it as a function-like macro\n"
    "// returning 0 on non-clang so the existing #ifs evaluate cleanly.\n"
    "#ifndef __clang__\n"
    "#define __has_warning(x) 0\n"
    "#endif\n\n"
)
p.write_text(src.replace(anchor, shim + anchor, 1), encoding="utf-8")
PYEOF

# ----------------------------------------------------------------------------
# Patch 2: build/vs_toolchain.py — neutralise _CopyDebugger.
run_py_patch \
  "vs_toolchain.py _CopyDebugger no-op" \
  "$V8_DIR/build/vs_toolchain.py" \
  "# libv8: _CopyDebugger neutralised" <<'PYEOF'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
m = re.search(r"^def _CopyDebugger\([^\n]*\):\n", src, flags=re.MULTILINE)
if not m:
    sys.exit("vs_toolchain.py: _CopyDebugger def not found")
start = m.end()
end_m = re.search(r"\n(def |if __name__)", src[start:])
end = start + (end_m.start() + 1 if end_m else len(src) - start)
body = (
    "  # libv8: _CopyDebugger neutralised — host debugger DLLs are not\n"
    "  # needed for a static-monolith build, and the windows-11-arm SDK\n"
    "  # installer ships only arm64 Debuggers (no x64 subset). The\n"
    "  # upstream body raises if anything is missing under Windows Kits\n"
    "  # \\10\\Debuggers\\<arch>\\, which we cannot satisfy on ARM hosts.\n"
    "  import sys as _sys\n"
    "  print('libv8: _CopyDebugger no-op (target_cpu=%s)' % target_cpu,\n"
    "        file=_sys.stderr)\n"
    "  return\n\n\n"
)
p.write_text(src[:start] + body + src[end:], encoding="utf-8")
PYEOF

# ----------------------------------------------------------------------------
# Patch 3: src/objects/js-atomics-synchronization.h — alignas the base.
run_py_patch \
  "js-atomics-synchronization.h: alignas on JSSynchronizationPrimitive" \
  "$V8_DIR/src/objects/js-atomics-synchronization.h" \
  "// libv8: alignas to match Torque tagged-size class alignment" <<'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
needle = ("V8_OBJECT class JSSynchronizationPrimitive : "
          "public AlwaysSharedSpaceJSObject {")
if needle not in src:
    sys.exit("js-atomics-synchronization.h: declaration line not found")
replacement = (
    "// libv8: alignas to match Torque tagged-size class alignment\n"
    "#if TAGGED_SIZE_8_BYTES\n"
    "#define LIBV8_JSSP_ALIGN alignas(uint64_t)\n"
    "#else\n"
    "#define LIBV8_JSSP_ALIGN\n"
    "#endif\n"
    "V8_OBJECT class LIBV8_JSSP_ALIGN JSSynchronizationPrimitive : "
    "public AlwaysSharedSpaceJSObject {"
)
p.write_text(src.replace(needle, replacement, 1), encoding="utf-8")
PYEOF

log "patch-v8.sh: done"
