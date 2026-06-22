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
mkdir -p "$(dirname "$OUT")"
"$CLANG" --no-default-config -isysroot / -mmacosx-version-min=10.9 -dynamiclib -fPIC -O2 \
    -install_name @rpath/libaudiotoolbox_compat.dylib \
    -compatibility_version 1.0.0 -current_version 1000.0.0 \
    -Wl,-reexport_framework,AudioToolbox \
    -Wl,-reexport_framework,AudioUnit \
    "$SRC" -o "$OUT"
echo "built $OUT"
