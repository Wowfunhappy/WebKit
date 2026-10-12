#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/AquaWebKitSupport/polyfill/polyfill-env.sh"
RRT_DEPS="$ROOT/AquaWebKitSupport/deps/build"
OUT="$ROOT/WebKitBuild/Release/atsc-rrt"
mkdir -p "$OUT"
"$CLANG" $MODERN "$ROOT/AquaWebKitSupport/tests/atsc-rrt/main.c" \
    -I"$RRT_DEPS/include/gstreamer-1.0" -I"$RRT_DEPS/include/glib-2.0" -I"$RRT_DEPS/lib/glib-2.0/include" \
    -L"$RRT_DEPS/lib" -Wl,-rpath,"$RRT_DEPS/lib" -lgstmpegts-1.0 -lgstreamer-1.0 \
    -lgobject-2.0 -lglib-2.0 -o "$OUT/atsc-rrt" >> /tmp/wk_build.log 2>&1
export GST_REGISTRY_FORK=no
"$OUT/atsc-rrt"
