#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/MavericksSupport/polyfill/polyfill-env.sh"
OUT="$ROOT/WebKitBuild/Release/iframe-history"
mkdir -p "$OUT"
"$CLANG" $MODERN -fno-objc-arc "$ROOT/MavericksSupport/tests/iframe-history/referrer.m" \
    -framework Cocoa -framework WebKit -o "$OUT/referrer" >> /tmp/wk_build.log 2>&1
"$OUT/referrer" "${1:-http://127.0.0.1:8000/referrer-policy/no-referrer/}"
