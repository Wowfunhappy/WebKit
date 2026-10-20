#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/AquaWebKitSupport/polyfill/polyfill-env.sh"
OUT="$ROOT/WebKitBuild/Release/iframe-history"
mkdir -p "$OUT"
"$CLANG" $MODERN -fno-objc-arc "$ROOT/AquaWebKitSupport/tests/iframe-history/wk2.m" \
    -framework Cocoa /System/Library/Frameworks/WebKit.framework/WebKit \
    -o "$OUT/iframe-history-wk2" >> /tmp/wk_build.log 2>&1
"$OUT/iframe-history-wk2" "$ROOT/LayoutTests/"
