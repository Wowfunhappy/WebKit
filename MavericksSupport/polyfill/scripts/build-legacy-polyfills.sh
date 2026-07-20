#!/bin/bash
#
# Builds the vendored 10.9 polyfill archive from source.
#
# These are the POSIX/libc implementations that 10.9's system libraries lack
# (clock_gettime, getentropy, os_unfair_lock, the *at() family, ...). They are
# copied verbatim from MavericksLegacySupport (a stripped MacPorts
# macports-legacy-support), so this directory holds vendored code only -- the
# port's own polyfills live in polyfill/polyfills/.
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
# -fvisibility=hidden: these land in libpolyfill.a, which is force-loaded into WebKit's binaries, so
# the definitions only need to satisfy references inside the image that pulled them in. Keeping them
# unexported is what stops the layer leaking outside WebKit (deps/build_deps.sh compiles the same
# sources into the vendored dylibs with this flag for the same reason).
CFLAGS="--no-default-config -isysroot / -mmacosx-version-min=10.9 -fPIC -fvisibility=hidden -O2 -I$INC"

objs=()
for c in "$SRC"/*.c; do
    o="$OBJDIR/$(basename "${c%.c}").o"
    "$CLANG" $CFLAGS -c "$c" -o "$o"
    objs+=("$o")
done

rm -f "$OUT"
"$AR" qc "$OUT" "${objs[@]}"
echo "built $OUT ($(/usr/bin/nm -g "$OUT" 2>/dev/null | grep -cE ' [TDSB] ') external defs from ${#objs[@]} objects)"
