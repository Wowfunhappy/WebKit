#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/MavericksSupport/polyfill/polyfill-env.sh"
OUT="$ROOT/WebKitBuild/Release/media-engine-initialization"
mkdir -p "$OUT"
"$CLANG" $HOST -fno-objc-arc "$ROOT/MavericksSupport/tests/media-engine-initialization/main.m" \
    -framework Cocoa -framework WebKit -o "$OUT/media-engine-initialization" >> /tmp/wk_build.log 2>&1
for fixture in MediaStream-video-element-displays-buffer MediaStream-video-element-video-tracks-disabled-then-enabled; do
    "$OUT/media-engine-initialization" "file://$ROOT/LayoutTests/fast/mediastream/$fixture.html" 8
done
