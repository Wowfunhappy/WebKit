#!/bin/bash
# Ordinary WebCodecs H.264 access units through the published system-memory decoder.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPS="$ROOT/MavericksSupport/deps/build"
WORK=$(mktemp -d /tmp/webkit-video-reordering.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
export LC_ALL=C
export GST_PLUGIN_SYSTEM_PATH="$DEPS/lib/gstreamer-1.0"
export GST_PLUGIN_PATH=""
export GST_REGISTRY="$WORK/registry.bin"
export GST_REGISTRY_FORK=no
export DYLD_FALLBACK_LIBRARY_PATH="$DEPS/lib"
"$ROOT/MavericksSupport/toolchain/build/clang/bin/clang" -mmacosx-version-min=10.9 -Wall \
    "$ROOT/MavericksSupport/tests/video-decoder-reordering.c" -o "$WORK/check" \
    -I"$DEPS/include/gstreamer-1.0" -I"$DEPS/include/glib-2.0" -I"$DEPS/lib/glib-2.0/include" \
    -L"$DEPS/lib" -Wl,-rpath,"$DEPS/lib" -lgstapp-1.0 -lgstreamer-1.0 -lgstbase-1.0 -lgobject-2.0 -lglib-2.0 \
    >> /tmp/wk_build.log 2>&1
for run in 1 2 3 4 5 6 7 8 9 10; do
    perl -e 'alarm 30; exec @ARGV' "$WORK/check" "$ROOT/LayoutTests/media/media-source/content/test-fragmented.mp4.annexb" \
        "$ROOT/LayoutTests/imported/w3c/web-platform-tests/webcodecs/h264.annexb"
    echo "PASS H.264 output ordering run $run"
done
