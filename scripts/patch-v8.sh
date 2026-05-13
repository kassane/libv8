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
  "object-macros.h: V8_ABSTRACT_OBJECT_PUSH pack(4) on MS ABI only" \
  "$V8_DIR/src/objects/object-macros.h" \
  "// libv8: V8_ABSTRACT_OBJECT_PUSH pack(4) on MS ABI only" <<'PYEOF'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")

# Strategy: replace the gcc/clang-branch V8_ABSTRACT_OBJECT_PUSH macro
# with a #if defined(_MSC_VER)/#else pair. clang-cl is the only thing
# that defines both __clang__ and _MSC_VER, so this picks up the MS ABI
# path used by windows-x64 while leaving regular gcc / clang (Linux,
# macOS) on the upstream pack(1) + -Werror=padded behaviour.
gcc_clang_re = re.compile(
    r'#define\s+V8_ABSTRACT_OBJECT_PUSH\s*\\\n'
    r'\s*_Pragma\("pack\(push\)"\)\s+_Pragma\("pack\(1\)"\)\s+'
    r'_Pragma\("GCC diagnostic push"\)\s*\\\n'
    r'\s*_Pragma\("GCC diagnostic error \\"-Wpadded\\""\)'
)
gcc_clang_replacement = (
    "// libv8: V8_ABSTRACT_OBJECT_PUSH pack(4) on MS ABI only\n"
    "// (clang-cl matches the gcc/clang branch because __clang__ is\n"
    "// defined, but MS ABI honours pack(1) strictly and gives\n"
    "// sizeof(ExtendedMap)=73 instead of Torque's 76. Itanium ABI\n"
    "// (Linux/macOS gcc/clang) already gives the right size via\n"
    "// inheritance-driven alignment, so leave pack(1) alone there.)\n"
    "#if defined(_MSC_VER)\n"
    "#define V8_ABSTRACT_OBJECT_PUSH                                           \\\n"
    "  _Pragma(\"pack(push)\") _Pragma(\"pack(4)\") _Pragma(\"GCC diagnostic push\") \\\n"
    "      _Pragma(\"GCC diagnostic ignored \\\"-Wpadded\\\"\")\n"
    "#else\n"
    "#define V8_ABSTRACT_OBJECT_PUSH                                           \\\n"
    "  _Pragma(\"pack(push)\") _Pragma(\"pack(1)\") _Pragma(\"GCC diagnostic push\") \\\n"
    "      _Pragma(\"GCC diagnostic error \\\"-Wpadded\\\"\")\n"
    "#endif"
)

# Pure-MSVC branch (no __clang__): keep pack(4) since MS ABI needs it
# and the silencing of warning 4820 is harmless.
msvc_re = re.compile(
    r'#define\s+V8_ABSTRACT_OBJECT_PUSH\s*\\\n'
    r'\s*__pragma\(pack\(push\)\)\s+__pragma\(pack\(1\)\)\s+'
    r'__pragma\(warning\(push\)\)\s*\\\n'
    r'\s*__pragma\(warning\(default : 4820\)\)'
)
msvc_replacement = (
    "#define V8_ABSTRACT_OBJECT_PUSH                                  \\\n"
    "  __pragma(pack(push)) __pragma(pack(4)) __pragma(warning(push)) \\\n"
    "      __pragma(warning(disable : 4820))"
)

n = 0
src, k = gcc_clang_re.subn(gcc_clang_replacement, src, count=1)
n += k
src, k = msvc_re.subn(msvc_replacement, src, count=1)
n += k
if n == 0:
    sys.exit("object-macros.h: no V8_ABSTRACT_OBJECT_PUSH patterns matched")
p.write_text(src, encoding="utf-8")
PYEOF

# ----------------------------------------------------------------------------
# Patch 5: src/base/flags.h — drop constexpr from defaulted operator==.
#
# Flags<EnumT, BitfieldT, BitfieldStorageT> is instantiated by V8 with
# BitfieldStorageT = std::atomic<unsigned char> (the
# IsolateExecutionModeFlag mask). The two defaulted comparison operators
#   constexpr bool operator==(const Flags& flags) const = default;
#   constexpr bool operator!=(const Flags& flags) const = default;
# require the underlying mask_ comparison to be constexpr, but
# std::atomic<T>::operator T() const is not constexpr in any libstdc++
# (the C++20 standard doesn't require it). Clang/libc++ on linux-x64
# instantiates the constexpr requirement lazily and never hits an
# error because V8 never calls Flags::operator== in a constexpr
# context; gcc instantiates eagerly and rejects the declaration.
#
# Dropping the constexpr keyword keeps the defaulted definition valid
# under non-constexpr semantics. Any actual constexpr use of operator==
# (none observed in V8 14.9) would have been ill-formed anyway.
run_py_patch \
  "flags.h: drop constexpr from defaulted operator==/!=" \
  "$V8_DIR/src/base/flags.h" \
  "// libv8: non-constexpr default operator== for std::atomic mask" <<'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
patches = [
    ("  constexpr bool operator==(const Flags& flags) const = default;",
     "  // libv8: non-constexpr default operator== for std::atomic mask\n"
     "  bool operator==(const Flags& flags) const = default;"),
    ("  constexpr bool operator!=(const Flags& flags) const = default;",
     "  bool operator!=(const Flags& flags) const = default;"),
]
applied = 0
for old, new in patches:
    if old in src:
        src = src.replace(old, new, 1)
        applied += 1
if applied == 0:
    sys.exit("flags.h: no defaulted constexpr operator==/!= found")
p.write_text(src, encoding="utf-8")
PYEOF

# ----------------------------------------------------------------------------
# Patch 6: src/objects/tagged.h — deduction guide takes T by const-ref.
#
# V8 has the CTAD pattern
#     Tagged(*this)        // *this is e.g. JSObject&
# in a bunch of inline functions. The matching deduction guide is
#     template <class T> Tagged(T object) -> Tagged<T>;
# which takes T *by value*, requiring a copy. JSObject inherits from
# HeapObjectLayout whose copy constructor is `= delete`, so this is
# ill-formed. clang on linux-x64 elides the copy via implementation-
# defined behaviour and never instantiates the copy ctor; gcc-12 on
# linux-arm64 reports `use of deleted function JSObject::JSObject(
# const JSObject&)`.
#
# Take T by const reference so deduction works without copying. T is
# still deduced as the bare type (references stripped during CTAD's
# normal rules), so callers don't need to change.
run_py_patch \
  "tagged.h: deduction guide takes T by const-ref" \
  "$V8_DIR/src/objects/tagged.h" \
  "// libv8: deduction guide takes T by const-ref" <<'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
old = (
    "template <class T>\n"
    "Tagged(T object) -> Tagged<T>;"
)
new = (
    "// libv8: deduction guide takes T by const-ref so CTAD does not\n"
    "// require the source to be copy-constructible (V8 HeapObjectLayout\n"
    "// and friends delete the copy ctor; gcc-12 then rejects\n"
    "// Tagged(*this) at deduction time).\n"
    "template <class T>\n"
    "Tagged(const T& object) -> Tagged<T>;"
)
if old not in src:
    sys.exit("tagged.h: deduction guide pattern not found")
src = src.replace(old, new, 1)
p.write_text(src, encoding="utf-8")
PYEOF

log "patch-v8.sh: done"
