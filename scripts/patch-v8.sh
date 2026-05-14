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
# Patch 3: [REVERTED — broke linux-x64 mksnapshot]
#
# A previous version added an explicit uint32_t libv8_base_pad_ to
# JSSynchronizationPrimitive to bump sizeof from 36 to 40 so derived
# classes (JSAtomicsMutex, JSAtomicsCondition) wouldn't land
# `owner_thread_id_` / `optional_padding_` in the base's tail padding.
# That fixed the Torque/C++ offset static_assert on windows-x64 and
# linux-arm64, but it grew sizeof(JSAtomicsMutex) from 40 to 44 on
# linux-x64 clang — which trips mksnapshot's runtime check
# `IsAligned(size_in_bytes, kTaggedSize)` (44 % 8 != 0).
#
# Revert: linux-x64 is the only required target and must stay green.
# windows-x64 / linux-arm64 fall back to their pre-existing
# JSAtomicsMutex offset failures, which are addressed by disabling the
# Windows targets entirely and leaving linux-arm64 to be sorted out by
# the gcc-14 toolchain upgrade + other patches (the assert may still
# fire there; handle that as a separate, focused fix).

# ----------------------------------------------------------------------------
# Patch 4: [REVERTED — see note]
#
# A previous version of this patch lifted V8_ABSTRACT_OBJECT_PUSH from
# pack(1) to pack(4) on MS ABI to "match" Torque's emitted kSize. That
# was based on a misread of the static_assert error: Torque's kSize for
# ExtendedMap is actually 73 (not 76), and on Itanium ABI gcc/clang
# already gives sizeof = 73 (derived class alignment is NOT forced up
# to base alignment under pack(1) on Itanium). Lifting pack made C++
# sizeof = 76 — moving AWAY from Torque's 73, not toward it — and
# regressed macos-arm64, linux-arm64, windows-x64 with `73 == 76`.
#
# The Windows-x64 ExtendedMap mismatch on MS ABI (which forces
# alignof(Derived) >= alignof(Base) so pack(1) gives sizeof = 76)
# cannot be fixed by any pack pragma — it requires either a Torque-side
# patch (kSize -> 76 on MS ABI) or a way to reduce class alignment
# below the base's, which no portable C++ attribute provides. Document
# the windows-x64 / windows-arm64 ExtendedMap fail and revisit if V8
# upstream ships a fix.

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

# ----------------------------------------------------------------------------
# Patch 7: src/objects/simd.cc — disable NEON64 fast path on gcc-arm64.
#
# V8 14.9's ArrayBufferFromHex / Uint8ArrayFromHex have NEON and SVE
# optimised fast paths gated on `#define NEON64`. Both fail on gcc-14:
#
#   * NEON path passes uint8x16_t where vmovn_u16 wants uint16x8_t and
#     similar implicit conversions — clang allows these, gcc enforces
#     strict typing of NEON intrinsics.
#   * SVE path uses `TARGET_SVE` attribute on functions that call SVE
#     intrinsics, but gcc requires `-march=armv8-a+sve` etc to enable
#     the ISA; the build doesn't pass it, so SVE intrinsics are
#     rejected with "requires the SVE ISA extension".
#
# Guard the `#define NEON64` block so it only activates on clang (or
# MSVC). gcc-arm64 falls back to the scalar implementation, which
# compiles and is functionally correct (just slower on hex conversion).
run_py_patch \
  "simd.cc: skip NEON fast path on gcc-arm64" \
  "$V8_DIR/src/objects/simd.cc" \
  "// libv8: skip NEON fast path on gcc-arm64" <<'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
old = (
    "#ifdef V8_HOST_ARCH_ARM64\n"
    "// We use Neon only on 64-bit ARM (because on 32-bit, some instructions and some\n"
    "// types are not available). Note that ARM64 is guaranteed to have Neon.\n"
    "#define NEON64\n"
    "#include <arm_neon.h>\n"
    "#endif"
)
new = (
    "// libv8: skip NEON fast path on gcc-arm64 — V8 14.9's intrinsic\n"
    "// type usage compiles on clang but trips strict gcc-14 typing for\n"
    "// vmovn_u16/vshlq_n_u64, and the SVE path needs -march flags gcc\n"
    "// isn't given. Scalar fallback is functionally correct.\n"
    "#if defined(V8_HOST_ARCH_ARM64) && \\\n"
    "    !(defined(__GNUC__) && !defined(__clang__))\n"
    "// We use Neon only on 64-bit ARM (because on 32-bit, some instructions and some\n"
    "// types are not available). Note that ARM64 is guaranteed to have Neon.\n"
    "#define NEON64\n"
    "#include <arm_neon.h>\n"
    "#endif"
)
if old not in src:
    sys.exit("simd.cc: NEON64 gate block not found")
p.write_text(src.replace(old, new, 1), encoding="utf-8")
PYEOF

# ----------------------------------------------------------------------------
# Patch 8: src/wasm/constant-expression-interface.cc — include managed-inl.h.
#
# `Managed<T>::From(Isolate*, size_t, std::shared_ptr<T>, AllocationType)`
# is defined inline in `src/objects/managed-inl.h`. This .cc file calls
# it for `Managed<FutexManagedObjectWaitList>` in WaitqueueNew but only
# includes `managed.h` (the non-inl forward declaration). Clang's link-
# time inlining hides the issue on linux-x64 / macos-arm64; gcc on
# linux-arm64 emits an unresolved external symbol at mksnapshot link
# time. Adding the -inl.h include surfaces the template body.
run_py_patch \
  "constant-expression-interface.cc: include managed-inl.h" \
  "$V8_DIR/src/wasm/constant-expression-interface.cc" \
  "// libv8: include managed-inl.h for Managed<T>::From" <<'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
anchor = '#include "src/wasm/constant-expression-interface.h"\n'
if anchor not in src:
    sys.exit("constant-expression-interface.cc: anchor include not found")
addition = (
    anchor
    + '// libv8: include managed-inl.h for Managed<T>::From template body\n'
    + '#include "src/objects/managed-inl.h"\n'
)
p.write_text(src.replace(anchor, addition, 1), encoding="utf-8")
PYEOF

# ----------------------------------------------------------------------------
# Patch 9: src/objects/js-atomics-synchronization.h — MS-ABI explicit
# padding for JSAtomicsMutex / JSAtomicsCondition.
#
# Symptom on windows-x64 (clang-cl, target=x64) and the win_clang_x64
# host-tool stage of windows-arm64 builds:
#
#   static_assert(kOwnerThreadIdOffset == offsetof(JSAtomicsMutex,
#                                                  owner_thread_id_))
#   evaluates to '40 == 36'
#   static_assert(kOptionalPaddingOffset == offsetof(JSAtomicsCondition,
#                                                   optional_padding_))
#   evaluates to '40 == 36'
#
# Torque emits kOwnerThreadIdOffset / kOptionalPaddingOffset as 40 on
# MS ABI builds. C++ offsetof comes out 36 because the C++ Itanium-
# style tail-padding reuse rule lets derived fields land in the base's
# trailing 4 bytes of implicit padding (JSSynchronizationPrimitive's
# data ends at 36, sizeof = 40).
#
# Fix (gated strictly on `_MSC_VER` so Itanium-ABI Linux/macOS are
# untouched, where the upstream layout already matches Torque):
#
#   * Add an explicit `uint32_t libv8_base_pad_` to
#     JSSynchronizationPrimitive — turns the implicit 4 bytes of tail
#     padding into a real data member. Derived classes can no longer
#     reuse it, so subclass fields now start at offset 40.
#   * Add `uint32_t libv8_mutex_trail_pad_` after
#     JSAtomicsMutex::owner_thread_id_ — keeps sizeof an even multiple
#     of kTaggedSize (8). Without it, sizeof = 40+4 = 44 and mksnapshot
#     fires `Check failed: IsAligned(size_in_bytes, kTaggedSize)`.
#   * Same trail pad on JSAtomicsCondition after `optional_padding_`.
run_py_patch \
  "js-atomics-synchronization.h: MS ABI explicit padding" \
  "$V8_DIR/src/objects/js-atomics-synchronization.h" \
  "// libv8: MS ABI explicit padding (Patch 9)" <<'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")

edits = [
    # JSSynchronizationPrimitive: explicit base pad.
    (
        "  ExternalPointerMember<kWaiterQueueNodeTag> waiter_queue_head_;\n"
        "  std::atomic<uint32_t> state_;\n"
        "} V8_OBJECT_END;",
        "  ExternalPointerMember<kWaiterQueueNodeTag> waiter_queue_head_;\n"
        "  std::atomic<uint32_t> state_;\n"
        "#if TAGGED_SIZE_8_BYTES && defined(_MSC_VER)\n"
        "  // libv8: MS ABI explicit padding (Patch 9) — defeats tail-\n"
        "  // padding reuse so JSAtomicsMutex::owner_thread_id_ /\n"
        "  // JSAtomicsCondition::optional_padding_ land at Torque-\n"
        "  // emitted offset 40 instead of being absorbed at 36.\n"
        "  uint32_t libv8_base_pad_;\n"
        "#endif\n"
        "} V8_OBJECT_END;",
    ),
    # JSAtomicsMutex: trailing pad to keep sizeof 8-aligned.
    (
        "  std::atomic<int32_t> owner_thread_id_;\n"
        "\n"
        "  // Defined out-of-line below the class so `offsetof` / `sizeof` on the\n"
        "  // still-incomplete type can appear in an initializer.\n"
        "  static const int kOwnerThreadIdOffset;\n"
        "  static const int kHeaderSize;\n"
        "} V8_OBJECT_END;",
        "  std::atomic<int32_t> owner_thread_id_;\n"
        "#if TAGGED_SIZE_8_BYTES && defined(_MSC_VER)\n"
        "  // libv8: trailing pad to keep sizeof 8-aligned for mksnapshot's\n"
        "  // IsAligned(size_in_bytes, kTaggedSize) runtime check.\n"
        "  uint32_t libv8_mutex_trail_pad_;\n"
        "#endif\n"
        "\n"
        "  // Defined out-of-line below the class so `offsetof` / `sizeof` on the\n"
        "  // still-incomplete type can appear in an initializer.\n"
        "  static const int kOwnerThreadIdOffset;\n"
        "  static const int kHeaderSize;\n"
        "} V8_OBJECT_END;",
    ),
    # JSAtomicsCondition: trailing pad inside the same TAGGED_SIZE_8_BYTES
    # block. The upstream optional_padding_ exists for the same purpose
    # on Itanium ABI; we additionally need a MS-ABI trailer.
    (
        "#if TAGGED_SIZE_8_BYTES\n"
        "  uint32_t optional_padding_;\n"
        "#endif  // TAGGED_SIZE_8_BYTES\n",
        "#if TAGGED_SIZE_8_BYTES\n"
        "  uint32_t optional_padding_;\n"
        "#if defined(_MSC_VER)\n"
        "  // libv8: MS ABI trailer to keep sizeof 8-aligned.\n"
        "  uint32_t libv8_cond_trail_pad_;\n"
        "#endif\n"
        "#endif  // TAGGED_SIZE_8_BYTES\n",
    ),
]

applied = 0
for old, new in edits:
    if old not in src:
        sys.exit(f"js-atomics-synchronization.h: edit anchor not found: {old[:60]!r}")
    src = src.replace(old, new, 1)
    applied += 1
if applied != 3:
    sys.exit(f"js-atomics-synchronization.h: expected 3 edits, applied {applied}")
p.write_text(src, encoding="utf-8")
PYEOF

# ----------------------------------------------------------------------------
# Patch 10: [REVERTED — broke linux-x64 + windows-arm64 in run 25843672238]
#
# The earlier version added a specialization
#   template <typename R, typename... Args>
#   struct ExtractCallableRunTypeImpl<std::function<R(Args...)>> {
#     using Type = R(Args...);
#   };
# to src/base/functional/bind-internal.h to fix the windows-x64
# "implicit instantiation of undefined template" error on
# std::function<bool()> reached through FunctionRef's default
# `RunType = FunctorTraits<Functor>::RunType` template arg.
#
# The patch was thought to be purely additive — adding a partial
# specialization to a forward-declared primary template that has no
# existing std::function specialization can only constrain previously-
# error code, not break previously-compiling code. But linux-x64
# (clang/libc++) and windows-arm64 (clang-cl/MS-STL) both regressed;
# linux-arm64 (gcc/libstdc++) stayed green.
#
# Reverted to keep linux-x64 (the one required target) green. The
# windows-x64 std::function failure remains. Re-investigate by
# fetching V8 14.9's actual bind-internal.h to identify which
# existing specialization conflicts (likely a generic
# `requires(requires { &Callable::operator(); })` callable spec that
# matches std::function and now ambiguates with the new partial), or
# attempt the alternative path of fixing FunctionRef's default
# template arg to be SFINAE-friendly via `requires` reordering.

log "patch-v8.sh: done"
