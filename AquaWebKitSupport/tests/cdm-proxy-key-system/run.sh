#!/bin/bash
# Checks that each GStreamer decryptor refuses a CDMProxy of another key system instead of casting it
# (see main.cpp).
#
#   bash AquaWebKitSupport/tests/cdm-proxy-key-system/run.sh [installed|build]
#
# "installed" (the default) runs against the WebCore install.sh put under
# /System/Library/Frameworks/WebKit.framework; "build" runs against the copy of the build's products
# (test-products-snapshot.sh), under the test-run lock, and only when WebKitBuild/Release still holds
# the build the copy holds; it names that build when it starts and in its last line. The harness
# compiles with a decryptor's own flags out of compile_commands.json.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BUILD="$REPO/WebKitBuild/Release"
MODE="${1:-installed}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cdmproxy.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT

case "$MODE" in
installed)
    WEBCORE=/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/WebCore
    JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore
    GSTLIB=/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/Frameworks/gstreamer/lib
    GLIBLIB=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks
    CXXLIB=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks
    ;;
build)
    ROOT="$REPO"
    . "$REPO/AquaWebKitSupport/scripts/test-run-lock.sh"
    . "$REPO/AquaWebKitSupport/scripts/test-products-snapshot.sh"
    trap 'rm -rf "$WORK"; release_products_lock; release_test_run_lock; tested_build_report' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    acquire_test_run_lock
    snapshot_test_products || { echo "could not copy the build products"; exit 1; }
    tested_build_report
    TREE_BUILD=$(finished_tree_build) || TREE_BUILD="(none finished)"
    if [ "$TREE_BUILD" != "$TEST_PRODUCTS_BUILD" ]; then
        echo "WebKitBuild/Release holds the build $TREE_BUILD, but the copy holds the build $TEST_PRODUCTS_BUILD; the harness compiles against the first and runs against the second"
        exit 1
    fi
    WEBCORE="$TEST_PRODUCTS/lib/WebCore.framework/Versions/A/WebCore"
    JSC="$TEST_PRODUCTS/lib/JavaScriptCore.framework/Versions/A/JavaScriptCore"
    GSTLIB="$TEST_PRODUCTS/lib/WebCore.framework/Versions/A/Frameworks/gstreamer/lib"
    GLIBLIB="$GSTLIB"
    CXXLIB="$TEST_PRODUCTS/lib"
    ;;
*)
    echo "usage: $0 [installed|build]"; exit 2 ;;
esac
[ -f "$BUILD/compile_commands.json" ] || { echo "no compile_commands.json -- build first (AquaWebKitSupport/build.sh)"; exit 1; }
[ -f "$WEBCORE" ] || { echo "no $WEBCORE"; exit 1; }

echo "### building the harness against $WEBCORE"
python3 - "$REPO" "$WORK" "$WEBCORE" "$JSC" "$GSTLIB" "$GLIBLIB" "$CXXLIB" <<'PY' > "$WORK/build.sh"
import json, shlex, subprocess, sys
repo, work, webcore, jsc, gstlib, gliblib, cxxlib = sys.argv[1:8]
entry = next(e for e in json.load(open(repo + "/WebKitBuild/Release/compile_commands.json")) if e["file"].endswith("/WebKitWidevineDecryptorGStreamer.cpp"))
arguments, flags, skip = shlex.split(entry["command"]), [], 0
for index, argument in enumerate(arguments):
    if skip:
        skip -= 1
        continue
    if argument in ("-o", "-MF", "-MT"):
        skip = 1
        continue
    # WebCore's precompiled header expects its inline functions from WebCore's own objects, which keep
    # them hidden; the harness compiles them itself.
    if argument == "-Xclang" and arguments[index + 1] in ("-include", "-include-pch"):
        skip = 3
        continue
    if argument in ("-c", "-MD") or argument.endswith(".cpp"):
        continue
    flags.append(argument)
link = [flags[0]] + [f for f in flags if f.startswith("-mmacosx-version-min")][:1]
sysroot = flags.index("-isysroot")
link += flags[sysroot:sysroot + 2]
rpaths = ["-Wl,-rpath," + gstlib, "-Wl,-rpath," + gliblib, "-Wl,-rpath," + cxxlib]
for line in subprocess.run(["otool", "-l", webcore], capture_output=True, text=True).stdout.splitlines():
    line = line.strip()
    if line.startswith("path ") and "(offset" in line:
        rpaths += ["-Wl,-rpath," + line.split()[1]]
print("set -e")
print("cd " + shlex.quote(repo + "/WebKitBuild/Release"))
print(" ".join(shlex.quote(f) for f in flags) + " -c " + shlex.quote(repo + "/AquaWebKitSupport/tests/cdm-proxy-key-system/main.cpp") + " -o " + shlex.quote(work + "/main.o"))
print(" ".join(shlex.quote(f) for f in link) + " -nostdlib++ -Wl,-client_name,TestWebCore -o " + shlex.quote(work + "/cdmproxy") + " " + shlex.quote(work + "/main.o")
      + " " + " ".join(shlex.quote(p) for p in [webcore, jsc, gstlib + "/libgstreamer-1.0.0.dylib", gstlib + "/libgstbase-1.0.0.dylib",
                                                gliblib + "/libglib-2.0.0.dylib", gliblib + "/libgobject-2.0.0.dylib",
                                                cxxlib + "/libc++.1.dylib", cxxlib + "/libc++abi.1.dylib"])
      + " " + " ".join(rpaths))
PY
bash "$WORK/build.sh" >> /tmp/wk_build.log 2>&1 || { echo "harness build failed; see /tmp/wk_build.log"; exit 1; }
if [ "$MODE" = build ]; then
    [ "$(finished_tree_build)" = "$TREE_BUILD" ] || { echo "WebKitBuild/Release changed while the harness was built"; exit 1; }
    bash "$REPO/AquaWebKitSupport/scripts/make-build-binaries-runnable.sh" --products="$TEST_PRODUCTS" "$WORK/cdmproxy" \
        || { echo "could not make the harness loadable"; exit 1; }
    export DYLD_FRAMEWORK_PATH="$TEST_PRODUCTS/lib${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
fi

echo "### running"
"$WORK/cdmproxy"
