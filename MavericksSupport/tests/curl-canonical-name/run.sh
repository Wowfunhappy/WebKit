#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
source "$ROOT/MavericksSupport/scripts/framework-layout.sh"
INSTALLED_LIB="$WEBCORE_BUNDLE/Versions/A/Frameworks/gstreamer/lib"
TEST_LIB="${1:-$INSTALLED_LIB}"
WORK=$(mktemp -d /tmp/webkit-curl-cname.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
CC="$ROOT/MavericksSupport/toolchain/build/clang/bin/clang"
HEADERS="$ROOT/MavericksSupport/deps/build/include"
"$CC" -mmacosx-version-min=10.9 -I"$HEADERS" -dynamiclib "$HERE/resolver.c" \
    -o "$WORK/resolver.dylib" >> /tmp/wk_build.log 2>&1
"$CC" -mmacosx-version-min=10.9 -I"$HEADERS" "$HERE/main.c" \
    "$TEST_LIB/libcurl.4.dylib" "$WORK/resolver.dylib" -Wl,-rpath,"$TEST_LIB" \
    -Wl,-rpath,"$INSTALLED_LIB" -o "$WORK/check" >> /tmp/wk_build.log 2>&1
DYLD_INSERT_LIBRARIES="$WORK/resolver.dylib" "$WORK/check"
