#!/usr/bin/env bash
# Apply surgical post-fetch patches to the V8 source tree to unblock V8
# 14.9 issues documented in PR #2. Each patch is idempotent: re-running
# is a no-op, and a future V8 bump that drops the underlying bug will
# cause the patch to silently skip (sentinel comment already present
# means it's done; missing target pattern means upstream changed).
#
# Patches applied:
#   1. src/base/macros.h — guard __has_warning with __clang__ so gcc-on-
#      arm64 doesn't choke on the clang-only preprocessor extension.
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
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ -d "$V8_DIR" ]] || die "v8 source not found at $V8_DIR (run fetch.sh first)"

run_py_patch() {
  local name="$1" file="$2" sentinel="$3"
  shift 3
  if [[ ! -f "$file" ]]; then
    warn "patch '$name': $file not found — skipping"
    return
  fi
  if grep -qF "$sentinel" "$file"; then
    log "patch '$name': already applied"
    return
  fi
  log "patch '$name': applying"
  python3 - "$file" "$@"
  grep -qF "$sentinel" "$file" \
    || die "patch '$name': sentinel '$sentinel' not present after edit (upstream changed?)"
}

# ----------------------------------------------------------------------------
# Patch 1: src/base/macros.h — guard __has_warning with __clang__.
run_py_patch \
  "macros.h __has_warning guard" \
  "$V8_DIR/src/base/macros.h" \
  "// libv8: guard clang-only __has_warning" <<'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
marker = "// libv8: guard clang-only __has_warning\n"
replacements = [
    ('#if __has_warning("-Wlifetime-safety")',
     marker + '#if defined(__clang__) && __has_warning("-Wlifetime-safety")'),
    ('#if __has_warning("-Wreturn-stack-address")',
     '#if defined(__clang__) && __has_warning("-Wreturn-stack-address")'),
]
for old, new in replacements:
    if old not in src:
        sys.exit(f"macros.h patch: pattern not found: {old!r}")
    src = src.replace(old, new, 1)
p.write_text(src, encoding="utf-8")
PYEOF

# ----------------------------------------------------------------------------
# Patch 2: build/vs_toolchain.py — neutralise _CopyDebugger.
#
# Upstream _CopyDebugger raises an Exception when
# C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\dbghelp.dll
# (or arm64\) is missing from the host SDK. On the windows-11-arm runner
# even with /features OptionId.WindowsDesktopDebuggers only the arm64
# subset lands — the x64 directory remains empty. The static V8 monolith
# embedder doesn't load these DLLs, so the strict check is unnecessary
# for our use case. Replace the entire function body with a no-op + log.
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
#
# JSSynchronizationPrimitive is declared inside V8_OBJECT (pack(4)). Its
# fields are:
#   ExternalPointerMember<...> waiter_queue_head_;   // 8 bytes
#   std::atomic<uint32_t>      state_;               // 4 bytes
# Torque assumes tagged-size (8 byte) alignment on the *class*, computing
# sizeof = round_up(header + 8 + 4, 8) = header + 16. MSVC under pack(4)
# disagrees and gives sizeof = header + 12, putting subclass fields 4
# bytes earlier than Torque-generated kOwnerThreadIdOffset /
# kOptionalPaddingOffset expect.
#
# Forcing alignas(uint64_t) on the class restores the tagged-size class
# alignment that Torque assumes, on both MSVC and gcc/clang. Inside
# pack(4) the alignas declaration is still honoured (alignas can request
# stricter alignment than pack permits). Gated on TAGGED_SIZE_8_BYTES so
# pointer-compression builds (tagged_size=4) keep their original layout.
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
