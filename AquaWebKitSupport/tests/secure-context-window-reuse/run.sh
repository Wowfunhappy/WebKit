#!/bin/bash
# Loads page.html from file:// in a WebKit1 host that has already touched JavaScript, and checks that
# the loaded document gets its own window with the [SecureContext] bindings on it. showPopover comes
# along as a second reading of the same gate: both it and the window-reuse restriction are enabled
# only for a host WebKit considers linked on or after the SDK that introduced them, which host.m asks
# for through WTF::enableAllSDKAlignedBehaviors().
set -eu
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="${SDK:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.9.sdk}"
mkdir -p "$HERE/build"
/usr/bin/clang -isysroot "$SDK" -o "$HERE/build/host" "$HERE/host.m" \
    -framework Cocoa -framework WebKit -Wno-deprecated-declarations -O0 -g 2>&1 | tee -a /tmp/wk_build.log

out=$("$HERE/build/host" "file://$HERE/page.html")
echo "$out"
result=$(echo "$out" | sed -n 's/^RESULT //p')
expected="undefined,object,function,function,true,function"
if [ "$result" = "$expected" ]; then
    echo "PASS"
else
    echo "FAIL: expected $expected"
    exit 1
fi
