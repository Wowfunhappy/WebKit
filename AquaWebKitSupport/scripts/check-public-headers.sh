#!/bin/bash
# check-public-headers.sh — every header stage-headers.sh shipped compiles the way a developer
# includes it, against the staged frameworks alone, deployment target 10.9, x86_64, with each of
#   - the modern SDK and the toolchain's clang
#   - the macOS 10.9 and 10.10 SDKs and the clang of Xcode 6 at /Applications/Xcode.app
#   - the macOS 10.9 SDK and the toolchain's clang, textually: that SDK's own module maps do not
#     build as Objective-C++ under a modern clang
# For each:
#   1. each header after <Cocoa/Cocoa.h>, as Objective-C and Objective-C++, and each JavaScriptCore
#      header by itself as C, whose C API is plain C; with modules, the framework's own headers are
#      read textually and every other framework as a module. Upstream's headers, like the SDK's
#      copies, assume Foundation is already imported.
#   2. with modules, @import of each framework's module
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/framework-layout.sh"

STAGE="$WK_STAGE_ROOT"
SDK="${AQUAWEBKIT_SDK:-$(dirname "$WK_REPO")/MacOSX26.1.sdk}"
CLANG="${AQUAWEBKIT_CLANG:-$WK_SUPPORT/toolchain/build/clang}/bin/clang"
XCODE=/Applications/Xcode.app/Contents/Developer
XCODE_CLANG="$XCODE/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
XCODE_SDKS="$XCODE/Platforms/MacOSX.platform/Developer/SDKs"
WORK="$WK_REPO/WebKitBuild/Release/header-check"
rm -rf "$WORK"

for f in "$XCODE_CLANG" "$XCODE_SDKS/MacOSX10.9.sdk" "$XCODE_SDKS/MacOSX10.10.sdk"; do
    [ -e "$f" ] || { echo "ERROR: $f is missing; install Xcode 6.2 at /Applications/Xcode.app" >&2; exit 1; }
done

FRAMEWORKS="JavaScriptCore:$JSC_BUNDLE WebKit:$WEBKIT_BUNDLE"

# One line per compile: framework, language, header.
mkdir -p "$WORK"
for entry in $FRAMEWORKS; do
    fw="${entry%%:*}"
    headers="$STAGE${entry#*:}/Versions/A/Headers"
    [ -n "$(ls "$headers"/*.h 2>/dev/null)" ] || { echo "ERROR: no headers in $headers" >&2; exit 1; }
    for h in "$headers"/*.h; do
        langs="objective-c objective-c++"
        [ "$fw" = JavaScriptCore ] && langs="$langs c"
        for lang in $langs; do echo "$fw $lang $(basename "$h")"; done
    done
done > "$WORK/jobs"

compile_one() {
    local fw="$1" lang="$2" h="$3" tag="$1-$2-$3"
    if [ "$lang" = c ]; then
        echo "#include <$fw/$h>" > "$RUN/tu/$tag"
    else
        printf '#import <Cocoa/Cocoa.h>\n#import <%s/%s>\n' "$fw" "$h" > "$RUN/tu/$tag"
    fi
    "$RUN_CLANG" -x "$lang" "${FLAGS[@]}" ${RUN_MODULES:+-fmodules -fmodule-name="$fw"} "$RUN/tu/$tag" > "$RUN/log/$tag" 2>&1 \
        || echo "FAIL $fw/$h ($lang)"
}
export -f compile_one

# $1 = name, $2 = clang, $3 = SDK, $4 = modules or textual. Prints the failures.
check_toolchain() {
    local name="$1" fails entry fw
    export RUN="$WORK/$name" RUN_CLANG="$2" RUN_MODULES=""
    [ "$4" = modules ] && RUN_MODULES=1
    mkdir -p "$RUN/tu" "$RUN/log"
    FLAGS=(-fsyntax-only -isysroot "$3" -mmacosx-version-min=10.9 -arch x86_64
           -F"$STAGE$FRAMEWORKS_DIR" -fmodules-cache-path="$RUN/modules")
    # Exported functions cannot carry arrays, so each job rebuilds FLAGS from its quoted form.
    export FLAGS_STR="$(printf '%q ' "${FLAGS[@]}")"
    fails="$(xargs -P "$(sysctl -n hw.ncpu)" -L 1 bash -c 'eval "FLAGS=($FLAGS_STR)"; compile_one "$@"' _ < "$WORK/jobs")"
    for entry in $FRAMEWORKS; do
        [ -n "$RUN_MODULES" ] || break
        fw="${entry%%:*}"
        echo "@import $fw;" > "$RUN/tu/import-$fw.m"
        "$RUN_CLANG" -x objective-c "${FLAGS[@]}" -fmodules "$RUN/tu/import-$fw.m" > "$RUN/log/import-$fw" 2>&1 \
            || fails="$fails
FAIL @import $fw"
    done
    echo "  $name: compiled $(wc -l < "$WORK/jobs" | tr -d ' ') header/language pairs${RUN_MODULES:+ and the module imports}" >&2
    echo "$fails" | grep . | sed "s/^/$name: /" || true
}

FAILS="$(check_toolchain modern-sdk "$CLANG" "$SDK" modules)
$(check_toolchain xcode6-10.9-sdk "$XCODE_CLANG" "$XCODE_SDKS/MacOSX10.9.sdk" modules)
$(check_toolchain xcode6-10.10-sdk "$XCODE_CLANG" "$XCODE_SDKS/MacOSX10.10.sdk" modules)
$(check_toolchain modern-clang-10.9-sdk "$CLANG" "$XCODE_SDKS/MacOSX10.9.sdk" textual)"

FAILS="$(echo "$FAILS" | grep . || true)"
if [ -n "$FAILS" ]; then
    echo "$FAILS" >&2
    echo "ERROR: shipped headers do not compile against the staged frameworks; the compiler output is in $WORK/<toolchain>/log" >&2
    exit 1
fi
echo "  every shipped header compiles against the staged frameworks alone"
