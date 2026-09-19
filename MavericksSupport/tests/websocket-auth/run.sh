#!/bin/bash
# Build the production WebSocket polyfill and test NTLM and Kerberos on loopback.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$ROOT/WebKitBuild/Release/websocket-auth-tests"
LOG=/tmp/wk_build.log
TC="$ROOT/MavericksSupport/toolchain/build/clang/bin"
SDK="${MAVERICKS_SDK:-$(dirname "$ROOT")/MacOSX26.1.sdk}"
DEPS="$ROOT/MavericksSupport/deps/build"
PF="$ROOT/MavericksSupport/polyfill/polyfills"
mkdir -p "$OUT"
MODERN="--no-default-config -isysroot $SDK -mmacosx-version-min=10.9 -O2 -Wno-deprecated-declarations"
echo "### websocket-auth test build" >> "$LOG"
"$TC/clang" -c $MODERN -Wno-objc-designated-initializers -I"$ROOT/MavericksSupport/polyfill/mechanism" -I"$PF/c" \
    -I"$DEPS/include" -I"$ROOT/MavericksSupport/source/WebCore/platform/network/cocoa" -fobjc-arc -fvisibility=hidden \
    -DWK_POLYFILL_UNIT=websocket "$PF/webkit/websocket.mm" -o "$OUT/websocket.o" >> "$LOG" 2>&1 \
  && "$TC/clang++" $MODERN -fobjc-arc -std=c++20 -c "$HERE/websocket-ntlm.mm" -o "$OUT/websocket-ntlm.o" >> "$LOG" 2>&1 \
  && "$TC/clang++" --no-default-config -isysroot "$SDK" -mmacosx-version-min=10.9 "$OUT/websocket-ntlm.o" "$OUT/websocket.o" \
       -o "$OUT/websocket-ntlm" -framework Foundation -framework CoreServices -framework Security -framework CFNetwork \
       -L"$DEPS/lib" -lcurl -lssl -lcrypto -lz -Wl,-rpath,"$DEPS/lib" -Wl,-undefined,dynamic_lookup >> "$LOG" 2>&1 \
  || { echo "websocket-auth: build FAILED (see $LOG)"; exit 1; }
python3 "$HERE/run-fixture.py" "$OUT/websocket-ntlm" "$OUT"
