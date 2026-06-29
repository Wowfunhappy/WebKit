#!/bin/bash
#
# Builds libcoretext_compat.dylib -- the 10.9 CoreText compatibility shim for the vendored GStreamer
# (see coretext_compat.c). It REEXPORTS the real CoreText framework and DEFINES the two 10.10+ OpenType
# feature dictionary-key constants that libharfbuzz imports. install-safari7.sh repoints libharfbuzz's
# CoreText dependency to @rpath/libcoretext_compat.dylib. Sibling of build-coreservices-compat.sh.
#
# Usage: build-coretext-compat.sh [<clang>] [<out.dylib>]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CLANG="${1:-$REPO/MavericksSupport/toolchain/build/clang/bin/clang}"
OUT="${2:-$HERE/lib/libcoretext_compat.dylib}"
SRC="$HERE/coretext_compat.c"
EXP="$HERE/libcoretext_compat.exp"

mkdir -p "$(dirname "$OUT")"
# --framework CoreFoundation resolves __CFConstantStringClassReference for the CFSTR() constants;
# --reexport-framework CoreText makes every real CoreText symbol libharfbuzz uses resolve through us.
# See reexport-shim.sh for the shared recipe.
source "$REPO/MavericksSupport/reexport-shim.sh"
build_reexport_shim --clang "$CLANG" --out "$OUT" \
    --install-name @rpath/libcoretext_compat.dylib --compat 1.0.0 --current 844.5.0 \
    --cflags "-fPIC -O2" --framework CoreFoundation \
    --reexport-framework CoreText --exported-symbols-list "$EXP" \
    "$SRC"
echo "built $OUT"
