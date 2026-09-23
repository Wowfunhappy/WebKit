#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/MavericksSupport/polyfill/polyfill-env.sh"
OUT="$ROOT/WebKitBuild/Release/iframe-history"
mkdir -p "$OUT"
"$CLANG" $MODERN -fno-objc-arc "$ROOT/MavericksSupport/tests/iframe-history/main.m" \
    -framework Cocoa -framework WebKit -o "$OUT/iframe-history" >> /tmp/wk_build.log 2>&1
"$OUT/iframe-history" "$ROOT/LayoutTests/"
