#!/bin/bash
# check-public-headers.sh — every header stage-headers.sh shipped compiles the way a developer
# includes it, against the staged frameworks alone: the modern SDK, deployment target 10.9, x86_64.
#   1. each header after <Cocoa/Cocoa.h>, as Objective-C and Objective-C++, and each JavaScriptCore
#      header by itself as C, whose C API is plain C; the framework's own headers are read
#      textually and every other framework as a module. Upstream's headers, like the SDK's copies,
#      assume Foundation is already imported.
#   2. @import of each framework's module
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/framework-layout.sh"

STAGE="$WK_STAGE_ROOT"
SDK="${MAVERICKS_SDK:-$(dirname "$WK_REPO")/MacOSX26.1.sdk}"
CLANG="${MAVERICKS_CLANG:-$WK_SUPPORT/toolchain/build/clang}/bin/clang"
WORK="$WK_REPO/WebKitBuild/Release/header-check"
rm -rf "$WORK"
mkdir -p "$WORK/tu" "$WORK/log"

FLAGS=(-fsyntax-only -isysroot "$SDK" -mmacosx-version-min=10.9 -arch x86_64
       -F"$STAGE$FRAMEWORKS_DIR" -F"$STAGE$PRIVATE_DIR" -fmodules-cache-path="$WORK/modules")

FRAMEWORKS="JavaScriptCore:$JSC_BUNDLE WebKit:$WEBKIT_BUNDLE WebKit2:$WEBKIT2_BUNDLE"

# Step 1. One line per compile: framework, language, header.
: > "$WORK/jobs"
for entry in $FRAMEWORKS; do
    fw="${entry%%:*}"
    headers="$STAGE${entry#*:}/Versions/A/Headers"
    [ -n "$(ls "$headers"/*.h 2>/dev/null)" ] || { echo "ERROR: no headers in $headers" >&2; exit 1; }
    for h in "$headers"/*.h; do
        langs="objective-c objective-c++"
        [ "$fw" = JavaScriptCore ] && langs="$langs c"
        for lang in $langs; do echo "$fw $lang $(basename "$h")"; done
    done
done >> "$WORK/jobs"

compile_one() {
    local fw="$1" lang="$2" h="$3" tag="$1-$2-$3"
    if [ "$lang" = c ]; then
        echo "#include <$fw/$h>" > "$WORK/tu/$tag"
    else
        printf '#import <Cocoa/Cocoa.h>\n#import <%s/%s>\n' "$fw" "$h" > "$WORK/tu/$tag"
    fi
    "$CLANG" -x "$lang" "${FLAGS[@]}" -fmodules -fmodule-name="$fw" "$WORK/tu/$tag" > "$WORK/log/$tag" 2>&1 \
        || echo "FAIL $fw/$h ($lang)"
}
export -f compile_one
export CLANG WORK
export FLAGS_STR="$(printf '%q ' "${FLAGS[@]}")"
# Exported functions cannot carry arrays, so each job rebuilds FLAGS from its quoted form.
FAILS="$(xargs -P "$(sysctl -n hw.ncpu)" -L 1 bash -c 'eval "FLAGS=($FLAGS_STR)"; compile_one "$@"' _ < "$WORK/jobs")"
echo "  compiled $(wc -l < "$WORK/jobs" | tr -d ' ') header/language pairs"

# Step 2.
for entry in $FRAMEWORKS; do
    fw="${entry%%:*}"
    echo "@import $fw;" > "$WORK/tu/import-$fw.m"
    "$CLANG" -x objective-c "${FLAGS[@]}" -fmodules "$WORK/tu/import-$fw.m" > "$WORK/log/import-$fw" 2>&1 \
        || FAILS="$FAILS
FAIL @import $fw"
done

FAILS="$(echo "$FAILS" | grep . || true)"
if [ -n "$FAILS" ]; then
    echo "$FAILS" >&2
    echo "ERROR: shipped headers do not compile against the staged frameworks; the compiler output is in $WORK/log" >&2
    exit 1
fi
echo "  every shipped header compiles against the staged frameworks alone"
