#!/bin/bash
# Build websocket.mm with the polyfill layer's own flags, link it into websocket-send-completion.mm, and run that against
# websocket-send-completion-server.py on 127.0.0.1:18992. Needs python3 and the deps and polyfill trees built.
#
#   AquaWebKitSupport/tests/websocket-send-completion/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$ROOT/WebKitBuild/Release/websocket-send-completion-tests"
LOG=/tmp/wk_build.log
TC="$ROOT/AquaWebKitSupport/toolchain/build/clang/bin"
SDK="${AQUAWEBKIT_SDK:-$(dirname "$ROOT")/MacOSX26.1.sdk}"
DEPS="$ROOT/AquaWebKitSupport/deps/build"
PF="$ROOT/AquaWebKitSupport/polyfill/polyfills"
mkdir -p "$OUT"
MODERN="--no-default-config -isysroot $SDK -mmacosx-version-min=10.9 -O2 -Wno-deprecated-declarations"
echo "### websocket-send-completion test build" >> "$LOG"
"$TC/clang" -c $MODERN -Wno-objc-designated-initializers -I"$ROOT/AquaWebKitSupport/polyfill/mechanism" -I"$PF/c" \
    -I"$DEPS/include" -I"$ROOT/AquaWebKitSupport/source/WebCore/platform/network/cocoa" -fobjc-arc -fvisibility=hidden \
    -DWK_POLYFILL_UNIT=websocket "$PF/webkit/websocket.mm" -o "$OUT/websocket.o" >> "$LOG" 2>&1 \
  && "$TC/clang++" $MODERN -fobjc-arc -std=c++20 -c "$HERE/websocket-send-completion.mm" -o "$OUT/websocket-send-completion.o" >> "$LOG" 2>&1 \
  && "$TC/clang++" --no-default-config -isysroot "$SDK" -mmacosx-version-min=10.9 "$OUT/websocket-send-completion.o" "$OUT/websocket.o" \
       -o "$OUT/websocket-send-completion" -framework Foundation -framework CoreServices -framework Security -framework CFNetwork \
       -L"$DEPS/lib" -lcurl -lssl -lcrypto -lz -Wl,-rpath,"$DEPS/lib" -Wl,-undefined,dynamic_lookup >> "$LOG" 2>&1 \
  || { echo "websocket-send-completion: build FAILED (see $LOG)"; exit 1; }
python3 "$HERE/websocket-send-completion-server.py" 18992 > "$OUT/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
for i in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 18992 2>/dev/null && break; sleep 0.5; done
kill -0 $SERVER 2>/dev/null || { echo "websocket-send-completion: the fixture did not start"; cat "$OUT/server.log"; exit 1; }
"$OUT/websocket-send-completion"
rc=$?
echo "--- server"; cat "$OUT/server.log"
exit $rc
