#!/bin/bash
# Build websocket.mm with the polyfill layer's own flags, link it into websocket-open-order.mm, and run that against
# websocket-open-order-server.py on 127.0.0.1:18987. Needs python3 and the deps and polyfill trees built.
#
#   MavericksSupport/tests/websocket-open-order/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$ROOT/WebKitBuild/Release/websocket-open-order-tests"
LOG=/tmp/wk_build.log
TC="$ROOT/MavericksSupport/toolchain/build/clang/bin"
SDK="${MAVERICKS_SDK:-$(dirname "$ROOT")/MacOSX26.1.sdk}"
DEPS="$ROOT/MavericksSupport/deps/build"
PF="$ROOT/MavericksSupport/polyfill/polyfills"
mkdir -p "$OUT"
MODERN="--no-default-config -isysroot $SDK -mmacosx-version-min=10.9 -O2 -Wno-deprecated-declarations"
echo "### websocket-open-order test build" >> "$LOG"
"$TC/clang" -c $MODERN -Wno-objc-designated-initializers -I"$ROOT/MavericksSupport/polyfill/mechanism" -I"$PF/c" \
    -I"$DEPS/include" -I"$ROOT/MavericksSupport/source/WebCore/platform/network/cocoa" -fobjc-arc -fvisibility=hidden \
    -DWK_POLYFILL_UNIT=websocket "$PF/webkit/websocket.mm" -o "$OUT/websocket.o" >> "$LOG" 2>&1 \
  && "$TC/clang++" $MODERN -fobjc-arc -std=c++20 -c "$HERE/websocket-open-order.mm" -o "$OUT/websocket-open-order.o" >> "$LOG" 2>&1 \
  && "$TC/clang++" --no-default-config -isysroot "$SDK" -mmacosx-version-min=10.9 "$OUT/websocket-open-order.o" "$OUT/websocket.o" \
       -o "$OUT/websocket-open-order" -framework Foundation -framework CoreServices -framework Security -framework CFNetwork \
       -L"$DEPS/lib" -lcurl -lssl -lcrypto -lz -Wl,-rpath,"$DEPS/lib" -Wl,-undefined,dynamic_lookup >> "$LOG" 2>&1 \
  || { echo "websocket-open-order: build FAILED (see $LOG)"; exit 1; }
python3 "$HERE/websocket-open-order-server.py" 18987 > "$OUT/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
for i in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 18987 2>/dev/null && break; sleep 0.5; done
kill -0 $SERVER 2>/dev/null || { echo "websocket-open-order: the fixture did not start"; cat "$OUT/server.log"; exit 1; }
"$OUT/websocket-open-order"
rc=$?
echo "--- server"; cat "$OUT/server.log"
exit $rc
