#!/bin/bash
# Exercises the Mach-O work WebCore does on Google's Widevine module
# (AquaWebKitSupport/source/WebCore/platform/graphics/gstreamer/eme/WidevineCdmImage.cpp) against real files on this host.
#
#   bash AquaWebKitSupport/tests/widevine-image/run.sh [<a-real-libwidevinecdm.dylib>] [<a-real.crx3>] [<firefox.complete.mar>]
#
# With no argument it builds its own subject: a dylib the modern linker chains the fixups of, which
# 10.9's dyld refuses outright ("load command 0x80000034 is unknown"). The test converts it, loads
# the result, and calls through it -- a bind (printf) and a rebase (a pointer to a static array)
# both have to be right for that to print. Passing a module downloaded from Google's update service
# exercises the retargeting pass on the file it exists for, and passing the CRX3 it came in
# exercises the signature the archive is opened through -- including what one changed byte does.
#
# Needs a built tree (WebKitBuild/Release + compile_commands.json) and the polyfill's gap library.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BUILD="$REPO/WebKitBuild/Release"
GAP="$REPO/AquaWebKitSupport/polyfill/build/libwidevinegap.dylib"
SDK="${AQUAWEBKIT_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"
TC="${AQUAWEBKIT_CLANG:-$REPO/AquaWebKitSupport/toolchain/build/clang}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wvimage.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT

[ -f "$REPO/compile_commands.json" ] || { echo "no compile_commands.json — build first (AquaWebKitSupport/build.sh)"; exit 1; }
[ -f "$GAP" ] || { echo "no $GAP — build it with polyfill/build-polyfill.sh"; exit 1; }

# The harness compiles with WidevineCdmImage.cpp's own flags, taken from the build itself, and
# links WTF out of the built JavaScriptCore.
echo "### building the harness"
"$REPO/AquaWebKitSupport/toolchain/build/python3/bin/python3" - "$REPO" "$WORK" <<'PY' > "$WORK/build.sh"
import json, shlex, sys
repo, work = sys.argv[1], sys.argv[2]
entry = next(e for e in json.load(open(repo + "/compile_commands.json")) if "WidevineCdmImage.cpp" in e["file"])
arguments, flags, skip = shlex.split(entry["command"]), [], 0
for i, argument in enumerate(arguments):
    if skip:
        skip -= 1
        continue
    if argument == "-Xclang" and i + 1 < len(arguments) and arguments[i + 1] in ("-include-pch", "-include"):
        skip = 3
        continue
    if argument == "-o":
        skip = 1
        continue
    if argument == "-c" or argument.endswith(".cpp"):
        continue
    flags.append(argument)
compile = " ".join(shlex.quote(f) for f in flags)
print("set -e")
print("cd " + shlex.quote(repo + "/WebKitBuild/Release"))
print(compile + " -c " + shlex.quote(repo + "/AquaWebKitSupport/source/WebCore/platform/graphics/gstreamer/eme/WidevineCdmImage.cpp") + " -o " + shlex.quote(work + "/image.o"))
print(compile + " -x objective-c++ -fno-objc-arc -c " + shlex.quote(repo + "/AquaWebKitSupport/source/WebCore/platform/graphics/gstreamer/eme/WidevineCdmArchive.mm") + " -o " + shlex.quote(work + "/archive.o"))
print(compile + " -c " + shlex.quote(repo + "/AquaWebKitSupport/source/WebCore/platform/graphics/gstreamer/eme/WidevineFirefoxArchive.cpp") + " -o " + shlex.quote(work + "/firefox.o"))
print(compile + " -c " + shlex.quote(repo + "/AquaWebKitSupport/tests/widevine-image/main.cpp") + " -o " + shlex.quote(work + "/main.o"))
print(shlex.quote(flags[0]) + " -o " + shlex.quote(work + "/wvimage") + " " + shlex.quote(work + "/image.o") + " " + shlex.quote(work + "/archive.o") + " " + shlex.quote(work + "/firefox.o") + " " + shlex.quote(work + "/main.o")
      + " -F " + shlex.quote(repo + "/WebKitBuild/Release/lib") + " -framework JavaScriptCore -framework Foundation -framework CoreFoundation -framework Security -lz -larchive")
PY
bash "$WORK/build.sh"

# The subject: chained fixups, plus a load command for a framework this host does not have, which
# is what the retargeting pass needs a donor for.
echo "### building a chained-fixups dylib"
cat > "$WORK/chained.c" <<'EOF'
#include <stdio.h>
static const char* kMessages[] = { "one", "two", "three" };
const char* const* messages = kMessages;
int chained_probe(int n)
{
    printf("chained_probe: %s\n", kMessages[n % 3]);
    return n * 7;
}
EOF
"$TC/bin/clang" --no-default-config -isysroot "$SDK" -mmacosx-version-min=10.9 -dynamiclib \
    -Wl,-fixup_chains -framework LocalAuthentication -install_name @loader_path/chained.dylib \
    -o "$WORK/chained.dylib" "$WORK/chained.c"

cat > "$WORK/load.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char** argv)
{
    void* module = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!module) { printf("dlopen FAILED: %s\n", dlerror()); return 1; }
    int (*probe)(int) = dlsym(module, "chained_probe");
    const char* const** messages = dlsym(module, "messages");
    if (!probe || !messages) { printf("symbols missing\n"); return 1; }
    printf("probe(4) = %d (28 expected), messages[1] = %s (two expected)\n", probe(4), (*messages)[1]);
    return probe(4) == 28 && !strcmp((*messages)[1], "two") ? 0 : 1;
}
EOF
"$TC/bin/clang" --no-default-config -isysroot "$SDK" -mmacosx-version-min=10.9 -Wno-implicit-function-declaration -o "$WORK/load" "$WORK/load.c"

echo "### 10.9 must refuse it as it stands"
if "$WORK/load" "$WORK/chained.dylib" > "$WORK/before.log" 2>&1; then
    echo "FAIL: the chained dylib loaded unconverted, so this proves nothing"; cat "$WORK/before.log"; exit 1
fi
grep -q "0x80000034 is unknown" "$WORK/before.log" || { echo "FAIL: refused for another reason:"; cat "$WORK/before.log"; exit 1; }
sed 's/^/    /' "$WORK/before.log"

echo "### converting, then loading and calling through it"
mkdir -p "$WORK/converted"
cp "$GAP" "$WORK/converted/"
"$WORK/wvimage" image "$WORK/chained.dylib" "$WORK/converted/chained.dylib" "$GAP"
"$WORK/load" "$WORK/converted/chained.dylib" | sed 's/^/    /'

if [ $# -ge 1 ]; then
    echo "### preparing $1"
    mkdir -p "$WORK/module"
    cp "$GAP" "$WORK/module/"
    "$WORK/wvimage" image "$1" "$WORK/module/libwidevinecdm.dylib" "$GAP"
    cat > "$WORK/openmodule.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char** argv)
{
    void* module = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!module) { printf("dlopen FAILED: %s\n", dlerror()); return 1; }
    printf("InitializeCdmModule_4 = %p, CreateCdmInstance = %p\n", dlsym(module, "InitializeCdmModule_4"), dlsym(module, "CreateCdmInstance"));
    return dlsym(module, "CreateCdmInstance") ? 0 : 1;
}
EOF
    "$TC/bin/clang" --no-default-config -isysroot "$SDK" -mmacosx-version-min=10.9 -o "$WORK/openmodule" "$WORK/openmodule.c"
    "$WORK/openmodule" "$WORK/module/libwidevinecdm.dylib" | sed 's/^/    /'
    "$TC/bin/clang" --no-default-config -isysroot "$SDK" -mmacosx-version-min=10.9 \
        -o "$WORK/host-paths" "$HERE/host-paths.c"
    "$WORK/host-paths" "$WORK/module/libwidevinecdm.dylib" "$WORK/module/libwidevinegap.dylib"
fi

if [ $# -ge 2 ]; then
    echo "### opening $2, and the same archive with one byte changed"
    "$WORK/wvimage" archive "$2" "$WORK/from-archive.dylib" | sed 's/^/    /'
    "$REPO/AquaWebKitSupport/toolchain/build/python3/bin/python3" -c \
        'import sys; d = bytearray(open(sys.argv[1], "rb").read()); d[len(d) // 2] ^= 1; open(sys.argv[2], "wb").write(bytes(d))' \
        "$2" "$WORK/tampered.crx3"
    if "$WORK/wvimage" archive "$WORK/tampered.crx3" "$WORK/tampered.dylib" > "$WORK/tampered.log" 2>&1; then
        echo "FAIL: a changed byte was accepted"; exit 1
    fi
    sed 's/^/    /' "$WORK/tampered.log"
fi

if [ $# -ge 3 ]; then
    echo "### Firefox MAR extraction and malformed index"
    "$WORK/wvimage" firefox "$3" "$WORK/firefox"
fi

echo "### PASS"
