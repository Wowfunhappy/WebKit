#!/bin/bash
#
# Builds libcoreservices_compat.dylib -- the 10.9 CoreServices compatibility shim for the vendored
# GStreamer (see coreservices_compat.c). It REEXPORTS the real CoreServices framework and DEFINES the
# two 10.10+ LaunchServices functions libgio imports (returning NULL). install-safari7.sh repoints
# every vendored GStreamer dylib's CoreServices dependency to @rpath/libcoreservices_compat.dylib.
# Sibling of build-libsystem-compat.sh (kept separate so the libc shim doesn't drag in CoreServices).
#
# Usage: build-coreservices-compat.sh [<clang>] [<out.dylib>]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CLANG="${1:-$REPO/MavericksSupport/toolchain/build/clang/bin/clang}"
OUT="${2:-$HERE/lib/libcoreservices_compat.dylib}"
SRC="$HERE/coreservices_compat.c"
EXP="$HERE/libcoreservices_compat.exp"

mkdir -p "$(dirname "$OUT")"
# Built against the 10.9 host SDK (-isysroot /, the helper default): the two functions are declared
# locally, not via the SDK, so they compile regardless of availability macros. The export list keeps the
# shim's own exports to exactly the two gap functions; the reexport makes every real CoreServices symbol
# resolve. See reexport-shim.sh for the shared recipe.
source "$REPO/MavericksSupport/reexport-shim.sh"
build_reexport_shim --clang "$CLANG" --out "$OUT" \
    --install-name @rpath/libcoreservices_compat.dylib --compat 1.0.0 --current 1226.0.0 \
    --cflags "-fPIC -O2" --reexport-framework CoreServices --exported-symbols-list "$EXP" \
    "$SRC"
echo "built $OUT"
