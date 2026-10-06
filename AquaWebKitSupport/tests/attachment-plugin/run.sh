#!/bin/bash
# Tests the installed WebKit frameworks. Build and install the port before running.
set -eu
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="${SDK:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.9.sdk}"
mkdir -p "$HERE/build"
/usr/bin/clang -isysroot "$SDK" -o "$HERE/build/host" "$HERE/host.m" \
    -framework Cocoa -framework WebKit -Wno-deprecated-declarations -O0 -g >> /tmp/wk_build.log 2>&1
"$HERE/build/host"
