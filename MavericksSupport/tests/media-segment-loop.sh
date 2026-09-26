#!/bin/bash
# Ordinary MP4/FLV segment loops against the published GStreamer libraries.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPS="$ROOT/MavericksSupport/deps/build"
WORK=$(mktemp -d /tmp/webkit-media-segment.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
export LC_ALL=C
export GST_PLUGIN_SYSTEM_PATH="${WK_SEGMENT_PLUGIN_PATH:-$DEPS/lib/gstreamer-1.0}"
export GST_PLUGIN_PATH=""
export GST_REGISTRY="$WORK/registry.bin"
export GST_REGISTRY_FORK=no
export DYLD_FALLBACK_LIBRARY_PATH="$DEPS/lib"
"$ROOT/MavericksSupport/toolchain/build/clang/bin/clang" -mmacosx-version-min=10.9 -Wall \
    "$ROOT/MavericksSupport/tests/media-segment-loop.c" -o "$WORK/check" \
    -I"$DEPS/include/gstreamer-1.0" -I"$DEPS/include/glib-2.0" -I"$DEPS/lib/glib-2.0/include" \
    -L"$DEPS/lib" -Wl,-rpath,"$DEPS/lib" -lgstreamer-1.0 -lgstbase-1.0 -lgobject-2.0 -lglib-2.0 \
    >> /tmp/wk_build.log 2>&1
FIXTURE="$ROOT/LayoutTests/media/content/test.mp4"
"$DEPS/bin/gst-launch-1.0" -q filesrc location="$FIXTURE" ! qtdemux name=d \
    d.video_0 ! queue ! h264parse ! flvmux name=m streamable=false ! filesink location="$WORK/test.flv" \
    d.audio_0 ! queue ! aacparse ! m.
check() { perl -e 'alarm 45; exec @ARGV' "$WORK/check" "$@"; }
check "file://$FIXTURE" 3
check "http://127.0.0.1$FIXTURE" 3
check "http://127.0.0.1$FIXTURE" 6.0272
check "http://127.0.0.1$WORK/test.flv" 3
