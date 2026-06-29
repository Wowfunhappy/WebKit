#!/bin/bash
# Builds libaudiotoolbox_compat.dylib -- the 10.9 AudioToolbox shim for the vendored GStreamer (see
# audiotoolbox_compat.c). Reexports AudioToolbox + AudioUnit so libgstosxaudio's AudioComponent binds
# resolve. install-safari7.sh repoints libgstosxaudio's AudioToolbox dep to @rpath/libaudiotoolbox_compat.dylib.
# Usage: build-audiotoolbox-compat.sh [<clang>] [<out.dylib>]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CLANG="${1:-$REPO/MavericksSupport/toolchain/build/clang/bin/clang}"
OUT="${2:-$HERE/lib/libaudiotoolbox_compat.dylib}"
SRC="$HERE/audiotoolbox_compat.c"
# See reexport-shim.sh for the shared recipe.
source "$REPO/MavericksSupport/reexport-shim.sh"
build_reexport_shim --clang "$CLANG" --out "$OUT" \
    --install-name @rpath/libaudiotoolbox_compat.dylib --compat 1.0.0 --current 1000.0.0 \
    --cflags "-fPIC -O2" \
    --reexport-framework AudioToolbox --reexport-framework AudioUnit \
    "$SRC"
echo "built $OUT"
