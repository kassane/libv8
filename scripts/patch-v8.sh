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
# Patch 3: src/objects/js-atomics-synchronization.h — explicit trailing
# padding member on JSSynchronizationPrimitive.
#
# Torque computes its kHeaderSize for JSSynchronizationPrimitive with
# tagged-size (8 byte) class alignment rounding: 24 (JSObject header) +
# 8 (waiter_queue_head_) + 4 (state_) → rounded up to 40 → places
# subclass fields at offset 40. C++ under V8_OBJECT's pack(4) lays the
# class out without trailing padding (sizeof = 36), and the C++ Itanium
# ABI lets derived classes reuse trailing tail padding of non-POD
# bases — so JSAtomicsMutex::owner_thread_id_ lands at 36, contradicting
# Torque's 40. (Same for JSAtomicsCondition::optional_padding_.) An
# alignas on the class fixes sizeof but doesn't disable tail-padding
# reuse, so the offsets stay wrong.
#
# Adding an *explicit* uint32_t data member at the end of the base
# class extends the in-data region to offset 40, preventing derived
# fields from landing in what used to be implicit padding. Gated on
# TAGGED_SIZE_8_BYTES so pointer-compression builds (tagged_size=4)
# keep their original layout.
run_py_patch \
  "js-atomics-synchronization.h: explicit trailing pad on base" \
  "$V8_DIR/src/objects/js-atomics-synchronization.h" \
  "// libv8: explicit trailing pad to defeat ABI tail-padding reuse" <<'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
needle = ("  ExternalPointerMember<kWaiterQueueNodeTag> waiter_queue_head_;\n"
          "  std::atomic<uint32_t> state_;\n")
if needle not in src:
    sys.exit("js-atomics-synchronization.h: field block not found")
replacement = (
    "  ExternalPointerMember<kWaiterQueueNodeTag> waiter_queue_head_;\n"
    "  std::atomic<uint32_t> state_;\n"
    "#if TAGGED_SIZE_8_BYTES\n"
    "  // libv8: explicit trailing pad to defeat ABI tail-padding reuse\n"
    "  // so JSAtomicsMutex::owner_thread_id_ /\n"
    "  // JSAtomicsCondition::optional_padding_ land at Torque-computed\n"
    "  // offset 40 instead of being absorbed at 36.\n"
    "  uint32_t libv8_base_pad_;\n"
    "#endif\n"
)
p.write_text(src.replace(needle, replacement, 1), encoding="utf-8")
PYEOF

# ----------------------------------------------------------------------------
# Patch 4: src/objects/object-macros.h — V8_ABSTRACT_OBJECT_PUSH pack(4).
#
# V8 14.9 declares ExtendedMap and other abstract base classes via
# V8_ABSTRACT_OBJECT, which expands to V8_ABSTRACT_OBJECT_PUSH using
# pragma pack(1) (vs V8_OBJECT_PUSH's pack(4)). Torque, however,
# generates kSize / field offsets assuming pack(4) for every
# @cppObjectLayoutDefinition class, regardless of abstract-ness.
#
# On the Itanium C++ ABI (gcc/clang on Linux/macOS), inheritance from a
# pack(4) parent makes derived alignment = max(parent_align, own_align)
# = 4 even when the derived class's own pack is 1, so sizeof rounds to
# the Torque-expected value and the asserts pass. On the MS ABI
# (clang-cl on Windows), pack(1) is honoured strictly: ExtendedMap
# sizeof = 73 instead of Torque's 76, and the 3-byte gap propagates
# into JSInterceptorMap::extended_padding_ / named_interceptor_ /
# indexed_interceptor_ offsets.
#
# Lift V8_ABSTRACT_OBJECT_PUSH to pack(4) so the C++ layout matches
# Torque's assumption universally. The change is a no-op on Linux
# (sizeof was already 76 due to inherited alignment).
run_py_patch \
  "object-macros.h: V8_ABSTRACT_OBJECT_PUSH pack(4)" \
  "$V8_DIR/src/objects/object-macros.h" \
  "// libv8: V8_ABSTRACT_OBJECT_PUSH pack(4) to match Torque" <<'PYEOF'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")

# Replace pack(1) → pack(4) only within the V8_ABSTRACT_OBJECT_PUSH
# macro definitions. There are typically two (gcc/clang vs MSVC); patch
# both, since Torque's assumption is global.
patterns = [
    # gcc/clang branch: _Pragma("pack(1)")
    (r'(#define\s+V8_ABSTRACT_OBJECT_PUSH[^\n]*\\\n\s*_Pragma\("pack\(push\)"\)\s+_Pragma\(")pack\(1\)("\))',
     r'\1pack(4)\2'),
    # MSVC branch: __pragma(pack(1))
    (r'(#define\s+V8_ABSTRACT_OBJECT_PUSH[^\n]*\\\n\s*__pragma\(pack\(push\)\)\s+__pragma\()pack\(1\)(\))',
     r'\1pack(4)\2'),
]
n = 0
for pat, repl in patterns:
    src, k = re.subn(pat, repl, src)
    n += k
if n == 0:
    sys.exit("object-macros.h: no V8_ABSTRACT_OBJECT_PUSH pack(1) match")

header = (
    "// libv8: V8_ABSTRACT_OBJECT_PUSH pack(4) to match Torque\n"
    "// (V8 14.9 ExtendedMap inherits as pack(1) but Torque computes\n"
    "// kSize assuming pack(4); MS ABI honours pack(1) strictly,\n"
    "// breaking JSInterceptorMap field-offset static_asserts on\n"
    "// windows-x64 clang-cl. No-op on Itanium ABI Linux/macOS.)\n"
)
# Place the header comment right before the first V8_ABSTRACT_OBJECT_PUSH
# define so the sentinel grep finds it.
m = re.search(r"^#define\s+V8_ABSTRACT_OBJECT_PUSH", src, flags=re.MULTILINE)
if not m:
    sys.exit("object-macros.h: V8_ABSTRACT_OBJECT_PUSH define not found post-patch")
src = src[:m.start()] + header + src[m.start():]
p.write_text(src, encoding="utf-8")
PYEOF

log "patch-v8.sh: done"
