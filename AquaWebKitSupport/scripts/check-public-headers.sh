#!/bin/bash
# check-public-headers.sh — every header stage-headers.sh shipped compiles the way a developer
# includes it, against the staged frameworks alone, deployment target 10.9, with each of
#   - the modern SDK and the toolchain's clang, x86_64
#   - the macOS 10.9 and 10.10 SDKs and the clang of Xcode 6 at /Applications/Xcode.app, x86_64 and
#     i386. The i386 slice, and so its declarations, are the stock 10.9 framework's, so an i386
#     header may fail only as the stock one does, with the same errors: some stock headers compile
#     only after the umbrella header.
#   - the macOS 10.9 SDK and the toolchain's clang, x86_64, textually: that SDK's own module maps
#     do not build as Objective-C++ under a modern clang
# For each:
#   1. each header after <Cocoa/Cocoa.h>, as Objective-C and Objective-C++, and each JavaScriptCore
#      header by itself as C, whose C API is plain C; with modules, the framework's own headers are
#      read textually and every other framework as a module. Upstream's headers, like the SDK's
#      copies, assume Foundation is already imported.
#   2. each framework's umbrella header after <Cocoa/Cocoa.h>, and with modules, the same as a module
#      and @import of the module; on i386 these give no diagnostic, warnings included, beyond the
#      stock framework's
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

# The stock frameworks alone, for the i386 comparison.
export STOCK_FRAMEWORKS="$WORK/stock-frameworks"
mkdir -p "$STOCK_FRAMEWORKS"
for fw in JavaScriptCore WebKit; do
    [ -d "$STOCK_BACKUP/$fw.framework/Headers" ] || { echo "ERROR: no stock $fw.framework in $STOCK_BACKUP" >&2; exit 1; }
    ln -s "$STOCK_BACKUP/$fw.framework" "$STOCK_FRAMEWORKS/$fw.framework"
done

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

# The diagnostics of a compiler log whose kind matches $2, each as header name and message.
diagnostics() {
    grep -E ": ($2): " "$1" | sed -E 's|^([^:]*/)?([^/:]+):[0-9]+:[0-9]+: |\2: |' | LC_ALL=C sort -u
}
export -f diagnostics

# $@ = clang arguments. The same compile against the stock frameworks alone, with its own module cache.
compile_stock() {
    "$RUN_CLANG" -F"$STOCK_FRAMEWORKS" "${FLAGS[@]}" -fmodules-cache-path="$RUN/stock-modules" "$@"
}
export -f compile_stock

compile_one() {
    local fw="$1" lang="$2" h="$3" tag="$1-$2-$3"
    if [ "$lang" = c ]; then
        echo "#include <$fw/$h>" > "$RUN/tu/$tag"
    else
        printf '#import <Cocoa/Cocoa.h>\n#import <%s/%s>\n' "$fw" "$h" > "$RUN/tu/$tag"
    fi
    "$RUN_CLANG" -x "$lang" "${FLAGS[@]}" ${RUN_MODULES:+-fmodules -fmodule-name="$fw"} "$RUN/tu/$tag" > "$RUN/log/$tag" 2>&1 \
        && return
    if [ "$RUN_ARCH" = i386 ] && [ -f "$STOCK_FRAMEWORKS/$fw.framework/Headers/$h" ] \
        && ! compile_stock -x "$lang" ${RUN_MODULES:+-fmodules -fmodule-name="$fw"} "$RUN/tu/$tag" > "$RUN/log/$tag.stock" 2>&1 \
        && [ "$(diagnostics "$RUN/log/$tag" error)" = "$(diagnostics "$RUN/log/$tag.stock" error)" ]; then
        echo "STOCK $fw/$h ($lang)"
    else
        echo "FAIL $fw/$h ($lang)"
    fi
}
export -f compile_one

# $1 = framework, $2 = tag, $3 = translation unit, $4... = clang arguments. On i386, a whole-framework
# import may give no diagnostic, warnings included, that the same import of the stock framework does not.
import_one() {
    local fw="$1" tag="$2" tu="$3" extra
    shift 3
    if ! "$RUN_CLANG" "${FLAGS[@]}" "$@" "$tu" > "$RUN/log/$tag" 2>&1; then
        echo "FAIL $tag"
    elif [ "$RUN_ARCH" = i386 ]; then
        compile_stock "$@" "$tu" > "$RUN/log/$tag.stock" 2>&1 || true
        extra="$(LC_ALL=C comm -23 <(diagnostics "$RUN/log/$tag" 'error|warning') <(diagnostics "$RUN/log/$tag.stock" 'error|warning'))"
        [ -z "$extra" ] || echo "FAIL $tag: diagnostics stock does not give: $(echo "$extra" | head -3 | tr '\n' ' ')"
    fi
}

# $1 = name, $2 = clang, $3 = SDK, $4 = modules or textual, $5 = architecture. Prints the failures.
check_toolchain() {
    local name="$1" fails entry fw
    export RUN="$WORK/$name" RUN_CLANG="$2" RUN_MODULES="" RUN_ARCH="$5"
    [ "$4" = modules ] && RUN_MODULES=1
    mkdir -p "$RUN/tu" "$RUN/log"
    FLAGS=(-fsyntax-only -isysroot "$3" -mmacosx-version-min=10.9 -arch "$5"
           -F"$STAGE$FRAMEWORKS_DIR" -fmodules-cache-path="$RUN/modules")
    # Exported functions cannot carry arrays, so each job rebuilds FLAGS from its quoted form.
    export FLAGS_STR="$(printf '%q ' "${FLAGS[@]}")"
    fails="$(xargs -P "$(sysctl -n hw.ncpu)" -L 1 bash -c 'eval "FLAGS=($FLAGS_STR)"; compile_one "$@"' _ < "$WORK/jobs")"
    for entry in $FRAMEWORKS; do
        fw="${entry%%:*}"
        printf '#import <Cocoa/Cocoa.h>\n#import <%s/%s.h>\n' "$fw" "$fw" > "$RUN/tu/umbrella-$fw.m"
        fails="$fails
$(import_one "$fw" "umbrella-$fw" "$RUN/tu/umbrella-$fw.m" -x objective-c)"
        [ -n "$RUN_MODULES" ] || continue
        echo "@import $fw;" > "$RUN/tu/import-$fw.m"
        fails="$fails
$(import_one "$fw" "import-$fw" "$RUN/tu/import-$fw.m" -x objective-c -fmodules)
$(import_one "$fw" "umbrella-module-$fw" "$RUN/tu/umbrella-$fw.m" -x objective-c -fmodules)"
    done
    echo "  $name: compiled $(wc -l < "$WORK/jobs" | tr -d ' ') header/language pairs and the umbrella imports${RUN_MODULES:+, also as modules}" >&2
    echo "$fails" | grep '^STOCK ' | sed "s/^STOCK /    fails as the stock framework's does: /" >&2 || true
    echo "$fails" | grep '^FAIL' | sed "s/^/$name: /" || true
}

FAILS="$(check_toolchain modern-sdk "$CLANG" "$SDK" modules x86_64)
$(check_toolchain xcode6-10.9-sdk "$XCODE_CLANG" "$XCODE_SDKS/MacOSX10.9.sdk" modules x86_64)
$(check_toolchain xcode6-10.10-sdk "$XCODE_CLANG" "$XCODE_SDKS/MacOSX10.10.sdk" modules x86_64)
$(check_toolchain xcode6-10.9-sdk-i386 "$XCODE_CLANG" "$XCODE_SDKS/MacOSX10.9.sdk" modules i386)
$(check_toolchain xcode6-10.10-sdk-i386 "$XCODE_CLANG" "$XCODE_SDKS/MacOSX10.10.sdk" modules i386)
$(check_toolchain modern-clang-10.9-sdk "$CLANG" "$XCODE_SDKS/MacOSX10.9.sdk" textual x86_64)"

FAILS="$(echo "$FAILS" | grep . || true)"
if [ -n "$FAILS" ]; then
    echo "$FAILS" >&2
    echo "ERROR: shipped headers do not compile against the staged frameworks; the compiler output is in $WORK/<toolchain>/log" >&2
    exit 1
fi
echo "  every shipped header compiles against the staged frameworks alone, an i386 one wherever the stock one does"
