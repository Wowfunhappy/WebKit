#!/bin/bash
# Localize the WebCore::NetworkStorageSession cookie-method STUBS in libpolyfill.a so they stop
# SHADOWING the real WebCore.framework implementations when WebKit2 links the archive.
#
# libpolyfill.a's prebuilt stub objects (webcore_stubs.o, final_stubs.o; no source recipe) provide
# global (T) return-0/no-op stubs for many WebCore functions. When WebKit2 links libpolyfill.a those
# objects are pulled in and their stub definitions win over the dynamic WebCore.framework definitions
# for callers inside WebKit2 (two-level namespace). For NetworkStorageSession's cookie methods this
# made the NetworkProcess's cookie paths NO-OPS:
#   - webcore_stubs.o: the DOM path (setCookiesFromDOM/cookiesForDOM/cookieRequestHeaderFieldValue/...)
#     -> document.cookie set/get + request cookie headers were dropped (no persistence).
#   - final_stubs.o:   the cookie-MANAGER path (getAllCookies/deleteAllCookies/getHostnamesWithCookies/
#     hasCookies/setCookies/getCookies/nsCookieStorage/cookieAcceptPolicy/...) -> "clear cookies",
#     cookie-management UI, extension cookies.getAll/remove, and ITP cookie ops were no-ops.
#
# Fix (localize-to-fix): make each shadowing stub LOCAL (T->t) so it no longer satisfies WebKit2's
# external reference, which then resolves to WebCore.framework's real implementation. ONLY symbols
# that WebCore.framework actually exports (T) are localized (a stub-only symbol has no real provider,
# so localizing it would break the link); everything else is left untouched (bulk-localize breaks
# browsing). Idempotent; keeps a .pre-cookiefix backup. Re-run after restoring libpolyfill.a.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TC="${MAVERICKS_CLANG:-/Users/jonathan/Desktop/Compilers/toolchains/clang-22}"
AR="$TC/bin/llvm-ar"
OBJCOPY="$TC/bin/llvm-objcopy"
LIB="$HERE/prebuilt/libpolyfill.a"
# Check exports against the WebCore that WebKit LINKS against (the build framework) when present —
# only symbols WebCore really IMPLEMENTS may be localized. Many cookie-manager methods (getAllCookies,
# deleteAllCookies, hasCookies, ...) are unimplemented on the backport (provided ONLY by the stub),
# so they must stay shadowed or the link fails with "undefined symbol".
WEBCORE="$HERE/../WebKitBuild/Release/lib/WebCore.framework/Versions/A/WebCore"
[ -f "$WEBCORE" ] || WEBCORE="/System/Library/PrivateFrameworks/WebCore.framework/Versions/A/WebCore"
OBJS="webcore_stubs.o final_stubs.o"

[ -x "$OBJCOPY" ] || OBJCOPY="$(command -v llvm-objcopy)"

[ -f "$LIB.pre-cookiefix" ] || { echo "Backing up -> $LIB.pre-cookiefix"; cp "$LIB" "$LIB.pre-cookiefix"; }

# Real (T) WebCore exports, captured once (large binary; use system nm).
WORK="$(mktemp -d -t cookiestubs)"
trap 'rm -rf "$WORK"' EXIT
nm -arch x86_64 "$WEBCORE" 2>/dev/null | awk '$2=="T"{print $3}' | sort -u > "$WORK/webcore_T.txt"

cd "$WORK"
for OBJ in $OBJS; do
    "$AR" x "$LIB" "$OBJ" 2>/dev/null || { echo "  (no $OBJ in archive, skip)"; continue; }
    # NetworkStorageSession cookie-method stubs (global T) in this object. Anchor to the MEMBER prefix
    # (^__ZNK?7WebCore21NetworkStorageSession) so free functions that merely take a NetworkStorageSession
    # or HTTPCookieAcceptPolicy *parameter* (e.g. createPrivateStorageSession) are NOT matched.
    # Exclude the cookie methods that are NOT implemented in the Mac source (NetworkStorageSessionCocoa.mm):
    # getCookies, capExpiryOfPersistentCookie, setAllCookiesToSameSiteStrict, setCookieFromDOM(Cookie),
    # cookieAcceptPolicy. The build-WebCore check below can be fooled by their libpolyfill stub being
    # *embedded* into WebCore.framework, so exclude them by name to avoid a fragile cross-framework
    # dependency on a stub. (setCookiesFromDOM = 17, kept; setCookieFromDOM = 16, excluded.)
    nm "$OBJ" | awk '$2=="T" && $3 ~ /^__ZNK?7WebCore21NetworkStorageSession/ {print $3}' | grep -iE 'ookie' \
        | grep -vE '21NetworkStorageSession(10getCookies|27capExpiryOfPersistentCookie|29setAllCookiesToSameSiteStrict|16setCookieFromDOM|18cookieAcceptPolicy)' \
        | sort -u > "all_$OBJ.txt"
    : > "loc_$OBJ.txt"
    while read -r s; do
        if grep -qxF "$s" "$WORK/webcore_T.txt"; then echo "$s" >> "loc_$OBJ.txt"; else echo "  SKIP (no real WebCore export): $s"; fi
    done < "all_$OBJ.txt"
    n=$(wc -l < "loc_$OBJ.txt" | tr -d ' ')
    echo "$OBJ: localizing $n cookie stub(s)"
    if [ "$n" -gt 0 ]; then
        "$OBJCOPY" --localize-symbols="loc_$OBJ.txt" "$OBJ"
        "$AR" r "$LIB" "$OBJ"
    fi
done
"$AR" s "$LIB" 2>/dev/null || true

echo "Done. Remaining cookie symbols still GLOBAL T in the archive (should be only stub-only / WebKit-owned):"
nm -A "$LIB" 2>/dev/null | grep ' T ' | grep -E 'NetworkStorageSession.*ookie' | sed -E 's|.*/([a-z_]+\.o):.*T (.*)|  \1: \2|' | head
