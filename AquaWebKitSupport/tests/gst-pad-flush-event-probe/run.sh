#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/AquaWebKitSupport/polyfill/polyfill-env.sh"
DEPS="$ROOT/AquaWebKitSupport/deps/build"
OUT="$ROOT/WebKitBuild/Release/gst-pad-flush-event-probe"
mkdir -p "$OUT"
"$CLANG" -x c -std=gnu2x $MODERN "$ROOT/AquaWebKitSupport/tests/gst-pad-flush-event-probe/main.c" \
    -I"$DEPS/include/gstreamer-1.0" -I"$DEPS/include/glib-2.0" -I"$DEPS/lib/glib-2.0/include" \
    -L"$DEPS/lib" -Wl,-rpath,"$DEPS/lib" -lgstreamer-1.0 -lgobject-2.0 -lglib-2.0 \
    -o "$OUT/gst-pad-flush-event-probe" >> /tmp/wk_build.log 2>&1
export GST_REGISTRY_FORK=no GST_PLUGIN_SYSTEM_PATH_1_0=
exec perl -e 'alarm 60; exec @ARGV' "$OUT/gst-pad-flush-event-probe"
