#!/bin/bash
# Localize the NetworkStorageSession cookie-method STUBS in libpolyfill.a's
# webcore_stubs.o so they stop SHADOWING the real WebCore.framework implementations.
#
# webcore_stubs.o (a prebuilt object in libpolyfill.a, no source recipe) provides
# return-0/no-op stubs for ~152 WebCore functions. When WebKit2 links libpolyfill.a
# the object is pulled in and its *global* (T) stub definitions win over the dynamic
# WebCore.framework definitions for any caller inside WebKit2 (two-level namespace).
# For NetworkStorageSession's cookie methods this made the NetworkProcess's
# document.cookie set/get + request-cookie-header paths NO-OPS: DOM-set cookies were
# silently dropped (never reached NSHTTPCookieStorage, never persisted). Verified via
# nm -arch x86_64 (WebKit2 defines T setCookiesFromDOM) + instrumentation (gate reached
# the call, real WebCore impl never ran).
#
# Fix (the project's localize-to-fix technique, cf. colorFromCocoaColor / SharedBuffer):
# make each shadowing stub LOCAL (T->t) so it no longer satisfies WebKit2's external
# reference, which then resolves to WebCore.framework's real implementation. Only the
# cookie methods are touched (all confirmed to have real WebCore.framework counterparts),
# NOT the other 144 stubs — bulk-localizing breaks browsing.
#
# Idempotent; keeps a .pre-cookiefix backup. Re-run after restoring libpolyfill.a.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TC="${MAVERICKS_CLANG:-/Users/jonathan/Desktop/Compilers/toolchains/clang-22}"
AR="$TC/bin/llvm-ar"
OBJCOPY="$TC/bin/llvm-objcopy"
NM="$TC/bin/llvm-nm"
LIB="$HERE/prebuilt/libpolyfill.a"
WEBCORE="/System/Library/PrivateFrameworks/WebCore.framework/Versions/A/WebCore"

[ -x "$OBJCOPY" ] || OBJCOPY="$(command -v llvm-objcopy)"
[ -x "$NM" ] || NM="$(command -v nm)"

[ -f "$LIB.pre-cookiefix" ] || { echo "Backing up -> $LIB.pre-cookiefix"; cp "$LIB" "$LIB.pre-cookiefix"; }

WORK="$(mktemp -d -t cookiestubs)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
"$AR" x "$LIB" webcore_stubs.o

# NetworkStorageSession cookie-method stubs (global T) in this object.
"$NM" webcore_stubs.o | awk '$2=="T"{print $3}' | grep 'NetworkStorageSession' | grep -iE 'ookie' | sort -u > syms.txt
echo "Cookie stubs to localize ($(wc -l < syms.txt | tr -d ' ')):"
while read -r s; do echo "  $s"; done < syms.txt

# Safety: each must have a real exported (T) counterpart in WebCore.framework.
if [ -f "$WEBCORE" ]; then
    while read -r s; do
        "$NM" "$WEBCORE" 2>/dev/null | grep -q " T ${s}\$" || echo "  WARN: no real WebCore export for $s (skipping localize would be unsafe)"
    done < syms.txt
fi

"$OBJCOPY" --localize-symbols=syms.txt webcore_stubs.o
"$AR" r "$LIB" webcore_stubs.o
"$AR" s "$LIB" 2>/dev/null || true

echo "Done. Verify the stubs are now local (t):"
"$NM" "$LIB" 2>/dev/null | grep -iE 'NetworkStorageSession.*(setCookiesFromDOM|cookiesForDOM)' | grep ' t ' | head -2 || echo "  (re-run nm to confirm)"
