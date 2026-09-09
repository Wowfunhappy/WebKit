#!/bin/bash
# Builds the WebKit1 host with the system clang against the 10.9 SDK's headers. It loads
# /System/Library/Frameworks/WebKit.framework at runtime, so it exercises whatever build
# install.sh last put in place.
set -eu
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="${SDK:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.9.sdk}"
mkdir -p "$HERE/build"
/usr/bin/clang -isysroot "$SDK" -o "$HERE/build/wk1host" "$HERE/wk1host.m" \
    -framework Cocoa -framework WebKit -Wno-deprecated-declarations -O0 -g 2>&1 | tee -a /tmp/wk_build.log
echo "built $HERE/build/wk1host"

# The self-signed wss server links the vendored BoringSSL, so it speaks the protocol versions the
# browser's ClientHello offers; the system's own OpenSSL 0.9.8 does not.
DEPS="$HERE/../../deps/build"
/usr/bin/clang -w -o "$HERE/build/wsselfsigned" "$HERE/wsselfsigned.c" \
    -I"$DEPS/include" -L"$DEPS/lib" -lssl -lcrypto -Wl,-rpath,"$DEPS/lib" 2>&1 | tee -a /tmp/wk_build.log
echo "built $HERE/build/wsselfsigned"
