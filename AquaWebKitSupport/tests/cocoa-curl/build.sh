#!/bin/bash
# Build the Cocoa curl transport tests against the current WebKitBuild/Release tree.
#
#   AquaWebKitSupport/tests/cocoa-curl/build.sh [test-name ...]     (default: every test here)
#
# Each .mm is a standalone program over the transport. It compiles with the flags the build gave the
# framework source it exercises -- a WebCore unified source for the tests over WebCore internals,
# WebDownloadCurl.mm for those over the public WebKit or WebKitLegacy API -- so
# every include path, define and -F is the build's own, and links the built frameworks as one of
# their allowed clients together with the shipped curl and BoringSSL and the polyfill archive the
# frameworks themselves carry. The .c test is a plain libcurl program. Binaries land in
# WebKitBuild/Release/cocoa-curl-tests/, each with a <name>.build naming the finished build it was
# compiled against; run.sh runs them only against the copy of that build (test-products-snapshot.sh),
# with every fixture server the tests expect.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BUILD="$ROOT/WebKitBuild/Release"
OUT="$BUILD/cocoa-curl-tests"
DEPS="$ROOT/AquaWebKitSupport/deps/build"
POLY="$ROOT/AquaWebKitSupport/polyfill/build"
TC="$ROOT/AquaWebKitSupport/toolchain/build/clang/bin"
LOG=/tmp/wk_build.log
CLIENT=TestWebCore
mkdir -p "$OUT"
. "$ROOT/AquaWebKitSupport/scripts/products-lock.sh"
TREE_BUILD=$(finished_tree_build) || {
    echo "cocoa-curl tests: WebKitBuild/Release holds no finished build -- run AquaWebKitSupport/build.sh" >&2
    exit 1
}

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
# A program whose build finished while the tree still held TREE_BUILD is stamped with it.
stamp() {
    if [ "$(finished_tree_build)" = "$TREE_BUILD" ]; then
        echo "$TREE_BUILD" > "$OUT/$1.build"
        echo "  built  $1"
    else
        echo "### $1: WebKitBuild/Release changed while it was built" >> "$LOG"
        echo "  FAILED $1 (see $LOG)"; rc=1
    fi
}
for t in "${TESTS[@]}"; do
    echo "### cocoa-curl test: $t" >> "$LOG"
    rm -f "$OUT/$t.build"
    if [ -f "$HERE/$t.c" ]; then
        if "$TC/clang" -mmacosx-version-min=10.9 -Wl,-headerpad_max_install_names -I"$DEPS/include" "$HERE/$t.c" -o "$OUT/$t" \
             -L"$DEPS/lib" -lcurl -lssl -lcrypto -Wl,-rpath,"$DEPS/lib" >> "$LOG" 2>&1; then
            stamp "$t"
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
    # <WebKitLegacy/X.h> resolves through the build's WebKitLegacy framework-header map.
    FLAGS="$FLAGS -F$BUILD/lib -I$BUILD/Source/WebKitLegacy/WebKitLegacy-framework-headers.hmap"
    if (cd "$BUILD" && eval "\"$TC/clang++\" $FLAGS -c \"$HERE/$t.mm\" -o \"$OUT/$t.o\"" >> "$LOG" 2>&1 \
        && "$TC/clang++" -mmacosx-version-min=10.9 -Wl,-headerpad_max_install_names "$OUT/$t.o" -o "$OUT/$t" \
             -F"$BUILD/lib" -framework WebCore -framework WebKit -framework JavaScriptCore $EXTRA_FW \
             -framework Foundation -framework AppKit -framework Security -Wl,-client_name,"$CLIENT" \
             -L"$DEPS/lib" -lcurl -lssl -lcrypto -lglib-2.0 -lgobject-2.0 "$POLY/libpolyfill.a" -L"$POLY" -lpolyfill_classes \
             -Wl,-rpath,"$BUILD/lib" -Wl,-rpath,"$DEPS/lib" -Wl,-rpath,"$POLY" >> "$LOG" 2>&1); then
        stamp "$t"
    else
        echo "  FAILED $t (see $LOG)"; rc=1
    fi
done
exit $rc
