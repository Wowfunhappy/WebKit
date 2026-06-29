#!/bin/bash
#
# Builds libsystem_compat.dylib -- the 10.9 compatibility shim for the vendored GStreamer
# (official Cerbero GStreamer 1.26.6, deploy target 10.13; see PROVENANCE.txt).
#
# The GStreamer dylibs import a handful of libc functions that postdate 10.9 (clock_gettime,
# the *at() family, utimensat, fdopendir, fclonefileat, getentropy, mkostemp,
# pthread_jit_write_protect[_supported]_np, syslog$DARWIN_EXTSN). This shim REEXPORTS the real
# /usr/lib/libSystem.B.dylib (so every normal libc symbol still resolves) and DEFINES exactly
# those gap functions -- reusing the project's existing polyfill sources
# (polyfill/legacy-support/src), NOT a private reimplementation. install-safari7.sh repoints
# every GStreamer dylib's /usr/lib/libSystem.B.dylib dependency to @rpath/libsystem_compat.dylib,
# so the existing libSystem bind ordinals resolve on 10.9 with no flat-namespace games.
#
# The export list (libsystem_compat.exp) restricts the shim's own exports to just the gap
# functions, so internal helpers the polyfill objects also define (jit.c's mmap wrapper,
# getentropy.c's error helper, ...) stay private and never shadow real libSystem symbols.
#
# Usage: build-libsystem-compat.sh [<clang>] [<out.dylib>]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CLANG="${1:-$REPO/MavericksSupport/toolchain/build/clang/bin/clang}"
OUT="${2:-$HERE/lib/libsystem_compat.dylib}"

LEGACY="$REPO/MavericksSupport/polyfill/legacy-support"
SRC="$LEGACY/src"
INC="$LEGACY/include"
EXP="$HERE/libsystem_compat.exp"

# Only the libc/POSIX gap-fill sources GStreamer needs -- deliberately NOT the higher-level
# framework shims (security.c, iokit.c, ...) that would drag Security/IOKit deps into a libc shim.
# atcalls/utimensat emulate the *at() calls via per-thread chdir, so pthread_chdir.c
# (which defines __mpls_best_fchdir) is part of the closure even though GStreamer never
# imports its symbols directly (the export list keeps them private).
SOURCES=(time atcalls utimensat fdopendir dirfuncs_compat clonefile jit syslog_extsn statxx getentropy mkostemp pthread_chdir)

# --no-default-config / -isysroot /: these sources are written against the 10.9 host SDK (their
# wrapper headers assume it), exactly as build-legacy-polyfills.sh compiles them. On the 10.9 SDK
# the inode-ABI functions (fstatat/fdopendir) already emit their $INODE64 symbols, which is what
# the 64-bit GStreamer dylibs import.
CFLAGS="--no-default-config -isysroot / -mmacosx-version-min=10.9 -fPIC -O2 -I$INC"

OBJDIR="$(mktemp -d -t libsystem_compat)"
trap 'rm -rf "$OBJDIR"' EXIT
objs=()
for s in "${SOURCES[@]}"; do
    o="$OBJDIR/$s.o"
    "$CLANG" $CFLAGS -c "$SRC/$s.c" -o "$o"
    objs+=("$o")
done

# Apple-internal libSystem runtime helpers the newer-SDK-built vendored libs import
# (CCRandomGenerateBytes, __darwin_check_fd_set_overflow, __availability_version_check). Lives beside
# this script, not in the macports legacy-support sources.
"$CLANG" $CFLAGS -c "$HERE/libsystem_compat_extra.c" -o "$OBJDIR/libsystem_compat_extra.o"
objs+=("$OBJDIR/libsystem_compat_extra.o")

# Reexport libSystem (not a framework) + restrict exports to the gap functions. See reexport-shim.sh.
source "$REPO/MavericksSupport/reexport-shim.sh"
build_reexport_shim --clang "$CLANG" --out "$OUT" \
    --install-name @rpath/libsystem_compat.dylib --compat 1.0.0 --current 1351.0.0 \
    --reexport-lib System --exported-symbols-list "$EXP" \
    "${objs[@]}"

echo "built $OUT"
echo "exports: $(/usr/bin/nm -gU "$OUT" 2>/dev/null | grep ' T ' | awk '{print $NF}' | tr '\n' ' ')"
