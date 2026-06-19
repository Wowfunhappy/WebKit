#!/bin/bash
#
# Builds the vendored 10.9 polyfill archive from source.
#
# These are the POSIX/libc/Security implementations that 10.9's system libraries
# lack (clock_gettime, getentropy, os_unfair_lock, the *at() family, SecTrust/
# SecKey modern entry points, ...). They are copied verbatim from
# MavericksLegacySupport (a stripped MacPorts macports-legacy-support) into
# legacy-polyfills/ so WebKit is self-contained and does not depend on the
# toolchain auto-linking that library.
#
# They are compiled against the 10.9 SDK (the host's own headers) because their
# wrapper headers assume it; the resulting objects are SDK-agnostic and link
# into the modern-SDK WebKit binaries unchanged.
#
# Usage: build-legacy-polyfills.sh <clang> <out.a> [<tmp-obj-dir>]
set -e

CLANG="${1:?clang path required}"
OUT="${2:?output archive path required}"
OBJDIR="${3:-$(dirname "$OUT")/legacy-polyfills-obj}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../legacy-support/src"
INC="$HERE/../legacy-support/include"
AR="$(dirname "$CLANG")/llvm-ar"

mkdir -p "$OBJDIR"
# --no-default-config: skip clang.cfg (frameworks/link flags meant for WebKit).
# -isysroot /: build against the 10.9 host SDK these sources were written for.
CFLAGS="--no-default-config -isysroot / -mmacosx-version-min=10.9 -fPIC -O2 -I$INC"

objs=()
for c in "$SRC"/*.c; do
    o="$OBJDIR/$(basename "${c%.c}").o"
    "$CLANG" $CFLAGS -c "$c" -o "$o"
    objs+=("$o")
done

rm -f "$OUT"
"$AR" qc "$OUT" "${objs[@]}"
echo "built $OUT ($(/usr/bin/nm -g "$OUT" 2>/dev/null | grep -cE ' [TDSB] ') external defs from ${#objs[@]} objects)"
