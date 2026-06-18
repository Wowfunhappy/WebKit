#!/bin/bash
# Localize the WebCore Color<->NSColor conversion STUBS in libpolyfill.a so they stop SHADOWING the
# real WebCore.framework implementations when WebKit2 links the archive. Sibling of
# localize-webcore-cookie-stubs.sh (same two-level-namespace shadow mechanism; see that file's header).
#
# webcore_stubs.o ships a global (T) return-0 stub for WebCore::cocoaColor(const Color&). WebCore.framework
# actually IMPLEMENTS cocoaColor (Source/WebCore/platform/graphics/mac/ColorMac.mm, a real cached impl using
# the 10.9-safe -[NSColor colorWithSRGBRed:...]), but because the stub is global it satisfies WebKit2's
# external reference first (two-level namespace) for every WebKit2-image caller, so they get a return-0
# (nil) NSColor instead of the real one. Silently broken on the Mac WK2 image:
#   - <input type=color> native picker (WebColorPickerMac.mm: initial color, shown color, suggestion swatches)
#   - WKWebView underPageBackgroundColor, CoreIPCColor IPC color serialization, WebViewImpl background capture
# The reverse direction, colorFromCocoaColor, was already localized (purple Top Sites title fix); this script
# localizes cocoaColor too and RE-ASSERTS colorFromCocoaColor so the color-stub set has one source of truth.
#
# Fix (localize-to-fix): make each shadowing stub LOCAL (T->t) so it no longer satisfies WebKit2's external
# reference, which then resolves to WebCore.framework's real implementation. ONLY symbols WebCore.framework
# actually exports (T) are localized (a stub-only symbol has no real provider, so localizing it breaks the
# link). Idempotent; keeps a .pre-colorfix backup. Re-run after restoring libpolyfill.a, then rebuild WebKit2.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TC="${MAVERICKS_CLANG:-/Users/jonathan/Desktop/Compilers/toolchains/clang-22}"
AR="$TC/bin/llvm-ar"
OBJCOPY="$TC/bin/llvm-objcopy"
LIB="$HERE/prebuilt/libpolyfill.a"
# Check exports against the WebCore that WebKit LINKS against (the build framework) when present —
# only symbols WebCore really IMPLEMENTS may be localized.
WEBCORE="$HERE/../WebKitBuild/Release/lib/WebCore.framework/Versions/A/WebCore"
[ -f "$WEBCORE" ] || WEBCORE="/System/Library/PrivateFrameworks/WebCore.framework/Versions/A/WebCore"
OBJS="webcore_stubs.o final_stubs.o"

# The color-conversion stubs to localize (mangled). Both are real WebCore exports on this backport.
COLOR_SYMS="__ZN7WebCore10cocoaColorERKNS_5ColorE __ZN7WebCore19colorFromCocoaColorEP7NSColor"

[ -x "$OBJCOPY" ] || OBJCOPY="$(command -v llvm-objcopy)"

[ -f "$LIB.pre-colorfix" ] || { echo "Backing up -> $LIB.pre-colorfix"; cp "$LIB" "$LIB.pre-colorfix"; }

# Real (T) WebCore exports, captured once (large binary; use system nm).
WORK="$(mktemp -d -t colorstubs)"
trap 'rm -rf "$WORK"' EXIT
nm -arch x86_64 "$WEBCORE" 2>/dev/null | awk '$2=="T"{print $3}' | sort -u > "$WORK/webcore_T.txt"

cd "$WORK"
for OBJ in $OBJS; do
    "$AR" x "$LIB" "$OBJ" 2>/dev/null || { echo "  (no $OBJ in archive, skip)"; continue; }
    # Of the target color symbols, keep only those (a) defined global T in THIS object and (b) really
    # exported (T) by WebCore.framework — otherwise localizing would leave the reference unsatisfied.
    : > "loc_$OBJ.txt"
    for s in $COLOR_SYMS; do
        if nm "$OBJ" 2>/dev/null | awk -v sym="$s" '$2=="T" && $3==sym {found=1} END{exit !found}'; then
            if grep -qxF "$s" "$WORK/webcore_T.txt"; then echo "$s" >> "loc_$OBJ.txt"; else echo "  SKIP (no real WebCore export): $s"; fi
        fi
    done
    n=$(wc -l < "loc_$OBJ.txt" | tr -d ' ')
    echo "$OBJ: localizing $n color stub(s)"
    if [ "$n" -gt 0 ]; then
        "$OBJCOPY" --localize-symbols="loc_$OBJ.txt" "$OBJ"
        "$AR" r "$LIB" "$OBJ"
    fi
done
"$AR" s "$LIB" 2>/dev/null || true

echo "Done. Color-conversion symbols still GLOBAL T in the archive (should be none):"
nm -A "$LIB" 2>/dev/null | grep ' T ' | grep -E '10cocoaColorERKNS_5ColorE|19colorFromCocoaColorEP7NSColor' | sed -E 's|.*/([a-z_]+\.o):.*T (.*)|  \1: \2|' || echo "  (none — good)"
