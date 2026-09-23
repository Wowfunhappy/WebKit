#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/MavericksSupport/polyfill/polyfill-env.sh"
OUT="$ROOT/WebKitBuild/Release/dashboard-regions"
mkdir -p "$OUT"
"$CLANG" $MODERN -fno-objc-arc "$ROOT/MavericksSupport/tests/dashboard-regions/main.m" \
    -framework Cocoa -framework WebKit -o "$OUT/dashboard-regions" >> /tmp/wk_build.log 2>&1
"$OUT/dashboard-regions" "$ROOT/LayoutTests/"
