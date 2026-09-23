#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/MavericksSupport/polyfill/polyfill-env.sh"
OUT="$ROOT/WebKitBuild/Release/video-frame-color-space"
mkdir -p "$OUT"
"$CLANG" --no-default-config -isysroot / -mmacosx-version-min=10.9 \
    "$ROOT/MavericksSupport/tests/video-frame-color-space/native.m" \
    -framework CoreFoundation -framework CoreGraphics -framework CoreVideo \
    -framework VideoToolbox -framework CoreMedia -o "$OUT/native" >> /tmp/wk_build.log 2>&1
exec "$OUT/native"
