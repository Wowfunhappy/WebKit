#!/bin/bash
# Build the Cocoa curl transport tests against the current WebKitBuild/Release tree.
#
#   MavericksSupport/tests/cocoa-curl/build.sh [test-name ...]     (default: every test here)
#
# Each .mm is a standalone program over the transport. It compiles with the flags the build gave the
# framework source it exercises -- a WebCore unified source for the tests over WebCore internals,
# WebDownloadCurl.mm for those over the public WebKit or WebKitLegacy API -- so
# every include path, define and -F is the build's own, and links the built frameworks as one of
# their allowed clients together with the shipped curl and BoringSSL and the polyfill archive the
# frameworks themselves carry. The .c test is a plain libcurl program. Binaries land in
# WebKitBuild/Release/cocoa-curl-tests/, and make-build-binaries-runnable.sh then makes them and the
# build tree they load loadable on 10.9. run.sh starts every fixture server the tests expect and runs
# them.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BUILD="$ROOT/WebKitBuild/Release"
OUT="$BUILD/cocoa-curl-tests"
DEPS="$ROOT/MavericksSupport/deps/build"
POLY="$ROOT/MavericksSupport/polyfill/build"
TC="$ROOT/MavericksSupport/toolchain/build/clang/bin"
LOG=/tmp/wk_build.log
CLIENT=TestWebCore
mkdir -p "$OUT"

# Compile flags of the build's own command for |anchor| (a source file name, or "WebCore" for the
# unified source that carries NetworkStorageSessionCocoa.mm), minus that command's input and output.
flags_for() {
    python3 - "$BUILD" "$1" <<'PY'
import json, pathlib, shlex, sys
build, anchor = pathlib.Path(sys.argv[1]), sys.argv[2]
for e in json.load(open(build / "compile_commands.json")):
    f = pathlib.Path(e["file"])
    if anchor == "WebCore":
        ok = "UnifiedSource" in e["file"] and f.suffix == ".mm" and f.is_file() and "NetworkStorageSessionCocoa.mm" in f.read_text()
    else:
        ok = e["file"].endswith("/" + anchor)
    if ok:
        args = shlex.split(e["command"]); out = []; i = 1
        while i < len(args):
            if args[i:i + 3] == ["-Xclang", "-include-pch", "-Xclang"]:
                if i + 3 >= len(args):
                    raise RuntimeError("Incomplete PCH argument group")
                i += 4
                continue
            a = args[i]; i += 1
            if a == "-o": i += 1; continue
            if a in ("-c", e["file"]): continue
            out.append(a)
        print(shlex.join(out)); break
PY
}
# Standalone tests parse the build's textual prefix headers with the same feature definitions.
# Force-including config.h supplies WebCore's configuration for every internal test.
WEBCORE_FLAGS="$(flags_for WebCore) -include $ROOT/Source/WebCore/config.h"
LEGACY_FLAGS=$(flags_for WebDownloadCurl.mm)
[ -n "$WEBCORE_FLAGS" ] && [ -n "$LEGACY_FLAGS" ] \
  || { echo "cocoa-curl tests: compile_commands.json lacks a transport source to take flags from" >&2; exit 1; }

TESTS=("$@"); [ ${#TESTS[@]} -gt 0 ] || TESTS=($(cd "$HERE" && ls *.mm *.c | sed 's/\.mm$//; s/\.c$//'))
rc=0
BUILT=()
for t in "${TESTS[@]}"; do
    echo "### cocoa-curl test: $t" >> "$LOG"
    if [ -f "$HERE/$t.c" ]; then
        if "$TC/clang" -mmacosx-version-min=10.9 -I"$DEPS/include" "$HERE/$t.c" -o "$OUT/$t" \
             -L"$DEPS/lib" -lcurl -lssl -lcrypto -Wl,-rpath,"$DEPS/lib" >> "$LOG" 2>&1; then
            echo "  built  $t"; BUILT+=("$OUT/$t")
        else
            echo "  FAILED $t (see $LOG)"; rc=1
        fi
        continue
    fi
    # WebCore internals take WebCore's flags. Programs over the public WebKit API take WebKitLegacy's:
    # WebKit's own prefix header defines `new`, which the public headers' `- (instancetype)new` cannot
    # survive, and the built WebKit.framework carries no WKWebView.h, so its header directories are named.
    FLAGS="$WEBCORE_FLAGS"; EXTRA_FW=""
    if ! grep -q '<WebCore/' "$HERE/$t.mm"; then
        if grep -q '<WebKit/' "$HERE/$t.mm"; then
            FLAGS="$LEGACY_FLAGS -I$ROOT/Source/WebKit/UIProcess/API/Cocoa -I$BUILD/WebKit/Headers"
        elif grep -q '<WebKitLegacy/' "$HERE/$t.mm"; then
            FLAGS="$LEGACY_FLAGS"
        fi
    fi
    grep -q '<WebKitLegacy/' "$HERE/$t.mm" && EXTRA_FW="-framework WebKitLegacy"
    # The build's WebKitLegacy/Headers forward to Source/WebKitLegacy paths, so both roots are named.
    FLAGS="$FLAGS -F$BUILD/lib $( [ -d "$BUILD/WebKitLegacy/Headers" ] && echo -I$BUILD/WebKitLegacy/Headers -I$ROOT/Source/WebKitLegacy )"
    if (cd "$BUILD" && eval "\"$TC/clang++\" $FLAGS -c \"$HERE/$t.mm\" -o \"$OUT/$t.o\"" >> "$LOG" 2>&1 \
        && "$TC/clang++" -mmacosx-version-min=10.9 "$OUT/$t.o" -o "$OUT/$t" \
             -F"$BUILD/lib" -framework WebCore -framework WebKit -framework JavaScriptCore $EXTRA_FW \
             -framework Foundation -framework AppKit -framework Security -Wl,-client_name,"$CLIENT" \
             -L"$DEPS/lib" -lcurl -lssl -lcrypto -lglib-2.0 -lgobject-2.0 "$POLY/libpolyfill.a" -L"$POLY" -lpolyfill_classes \
             -Wl,-rpath,"$BUILD/lib" -Wl,-rpath,"$DEPS/lib" -Wl,-rpath,"$POLY" >> "$LOG" 2>&1); then
        echo "  built  $t"; BUILT+=("$OUT/$t")
    else
        echo "  FAILED $t (see $LOG)"; rc=1
    fi
done
if [ ${#BUILT[@]} -gt 0 ] && ! bash "$ROOT/MavericksSupport/scripts/make-build-binaries-runnable.sh" "${BUILT[@]}" >> "$LOG" 2>&1; then
    echo "  FAILED to make the build tree and tests loadable (see $LOG)"; rc=1
fi
exit $rc
