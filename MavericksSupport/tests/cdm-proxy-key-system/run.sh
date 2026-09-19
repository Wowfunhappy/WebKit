#!/bin/bash
# Checks that each GStreamer decryptor refuses a CDMProxy of another key system instead of casting it
# (see main.cpp).
#
#   bash MavericksSupport/tests/cdm-proxy-key-system/run.sh [installed|build]
#
# "installed" (the default) runs against the WebCore install.sh put under
# /System/Library/Frameworks/WebKit.framework; "build" runs against WebKitBuild/Release/lib. The
# harness compiles with a decryptor's own flags out of compile_commands.json.
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
    CXXLIB=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks
    ;;
build)
    WEBCORE="$BUILD/lib/WebCore.framework/Versions/A/WebCore"
    JSC="$BUILD/lib/JavaScriptCore.framework/Versions/A/JavaScriptCore"
    GSTLIB="$REPO/MavericksSupport/deps/build/lib"
    CXXLIB="$REPO/MavericksSupport/toolchain/build/clang/lib"
    ;;
*)
    echo "usage: $0 [installed|build]"; exit 2 ;;
esac
[ -f "$BUILD/compile_commands.json" ] || { echo "no compile_commands.json -- build first (MavericksSupport/build.sh)"; exit 1; }
[ -f "$WEBCORE" ] || { echo "no $WEBCORE"; exit 1; }

echo "### building the harness against $WEBCORE"
python3 - "$REPO" "$WORK" "$WEBCORE" "$JSC" "$GSTLIB" "$CXXLIB" <<'PY' > "$WORK/build.sh"
import json, shlex, subprocess, sys
repo, work, webcore, jsc, gstlib, cxxlib = sys.argv[1:7]
entry = next(e for e in json.load(open(repo + "/WebKitBuild/Release/compile_commands.json")) if e["file"].endswith("/WebKitWidevineDecryptorGStreamer.cpp"))
arguments, flags, skip = shlex.split(entry["command"]), [], 0
for argument in arguments:
    if skip:
        skip -= 1
        continue
    if argument in ("-o", "-MF", "-MT"):
        skip = 1
        continue
    if argument in ("-c", "-MD") or argument.endswith(".cpp"):
        continue
    flags.append(argument)
link = [flags[0]] + [f for f in flags if f.startswith("-mmacosx-version-min")][:1]
sysroot = flags.index("-isysroot")
link += flags[sysroot:sysroot + 2]
rpaths = ["-Wl,-rpath," + gstlib, "-Wl,-rpath," + cxxlib]
for line in subprocess.run(["otool", "-l", webcore], capture_output=True, text=True).stdout.splitlines():
    line = line.strip()
    if line.startswith("path ") and "(offset" in line:
        rpaths += ["-Wl,-rpath," + line.split()[1]]
print("set -e")
print("cd " + shlex.quote(repo + "/WebKitBuild/Release"))
print(" ".join(shlex.quote(f) for f in flags) + " -c " + shlex.quote(repo + "/MavericksSupport/tests/cdm-proxy-key-system/main.cpp") + " -o " + shlex.quote(work + "/main.o"))
print(" ".join(shlex.quote(f) for f in link) + " -nostdlib++ -Wl,-client_name,TestWebCore -o " + shlex.quote(work + "/cdmproxy") + " " + shlex.quote(work + "/main.o")
      + " " + " ".join(shlex.quote(p) for p in [webcore, jsc, gstlib + "/libgstreamer-1.0.0.dylib", gstlib + "/libgstbase-1.0.0.dylib",
                                                gstlib + "/libglib-2.0.0.dylib", gstlib + "/libgobject-2.0.0.dylib",
                                                cxxlib + "/libc++.1.dylib", cxxlib + "/libc++abi.1.dylib"])
      + " " + " ".join(rpaths))
PY
bash "$WORK/build.sh" >> /tmp/wk_build.log 2>&1 || { echo "harness build failed; see /tmp/wk_build.log"; exit 1; }

echo "### running"
"$WORK/cdmproxy"
