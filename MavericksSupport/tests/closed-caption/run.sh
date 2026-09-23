#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/MavericksSupport/polyfill/polyfill-env.sh"
CAPTION_DEPS="$ROOT/MavericksSupport/deps/build"
OUT="$ROOT/WebKitBuild/Release/closed-caption"
mkdir -p "$OUT"
"$CLANG" $MODERN "$ROOT/MavericksSupport/tests/closed-caption/main.c" \
    -I"$CAPTION_DEPS/include/gstreamer-1.0" -I"$CAPTION_DEPS/include/glib-2.0" -I"$CAPTION_DEPS/lib/glib-2.0/include" \
    -L"$CAPTION_DEPS/lib" -Wl,-rpath,"$CAPTION_DEPS/lib" -lgstapp-1.0 -lgstreamer-1.0 \
    -lgobject-2.0 -lglib-2.0 -o "$OUT/closed-caption" >> /tmp/wk_build.log 2>&1
export GST_REGISTRY_FORK=no GST_PLUGIN_SYSTEM_PATH= GST_PLUGIN_PATH="$CAPTION_DEPS/lib/gstreamer-1.0"
exec "$OUT/closed-caption"
