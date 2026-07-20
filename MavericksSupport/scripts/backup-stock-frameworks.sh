#!/bin/bash
# backup-stock-frameworks.sh — keep the factory (stock) 10.9 WebKit frameworks in
# $STOCK_BACKUP, adjacent to the checkout (a sibling dir, like the SDK).
#
# The build needs them: stock 10.9 shipped WebKit fat (x86_64 + i386) and 10.9 still runs
# 32-bit apps, so the product's four framework binaries carry the ORIGINAL stock i386 slice
# grafted back in (stage-frameworks.sh). That slice exists nowhere else once an install has
# happened, which is why this runs at BUILD time and captures stock the first time it sees it.
#
# This build is self-hosted, so the running 10.9 system IS the source of stock. The rule:
#   backup complete            -> use it, touch nothing
#   backup incomplete + system vanilla -> capture from /System, refresh MANIFEST.txt
#   backup incomplete + system ours    -> hard fail; stock is unrecoverable here and shipping
#                                         x86_64-only frameworks breaks every 32-bit WebView app
#
# Vanilla detection is positive evidence, never size or date: every binary this project builds
# carries a __DATA,__wk_marker section (MavericksSupport/polyfill/mechanism/wk_image_marker.c,
# force-loaded by _WEBKIT_FORCE_LOAD_POLYFILL in Source/cmake/WebKitMacros.cmake) and stock 10.9
# binaries are fat with an i386 slice, so stock is exactly "no marker AND has i386".
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/framework-layout.sh"
OTOOL="$(wk_find_otool)"
LIPO="$(wk_find_lipo)"

# The stock binaries the i386 graft consumes, as "<backup-relative path>:<system path>".
# WebCore is nested inside WebKit.framework on stock 10.9, so it rides along with that copy.
STOCK_BINARIES="JavaScriptCore.framework/Versions/A/JavaScriptCore:$JSC_BUNDLE/Versions/A/JavaScriptCore
WebKit.framework/Versions/A/WebKit:$WEBKIT_BUNDLE/Versions/A/WebKit
WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/WebCore:$WEBCORE_BUNDLE/Versions/A/WebCore
WebKit2.framework/Versions/A/WebKit2:$WEBKIT2_BUNDLE/Versions/A/WebKit2"

# A stock binary: no __DATA,__wk_marker, and fat with an i386 slice.
is_stock_macho() {
    local bin="$1"
    [ -f "$bin" ] || return 1
    if "$OTOOL" -l "$bin" 2>/dev/null | grep -q '__wk_marker'; then return 1; fi
    case "$("$LIPO" -info "$bin" 2>/dev/null)" in
        *i386*) return 0;;
        *) return 1;;
    esac
}

# MANIFEST.txt records what the backup holds: one line per top-level framework, naming its
# binary and size. Regenerated from the backup itself, so a framework captured by an earlier
# run (Safari, which the installer never replaces) keeps its entry.
write_manifest() {
    local out="$STOCK_BACKUP/MANIFEST.txt" fw name bin
    : > "$out"
    for fw in "$STOCK_BACKUP"/*.framework; do
        [ -d "$fw" ] || continue
        name="$(basename "$fw" .framework)"
        bin="$fw/Versions/A/$name"
        [ -f "$bin" ] || continue
        echo "$name: $bin: size=$(stat -f%z "$bin")" >> "$out"
    done
    echo "  refreshed $out"
}

echo "### Stock 10.9 framework backup ($STOCK_BACKUP)"
missing=""
while IFS= read -r entry; do
    rel="${entry%%:*}"
    if ! is_stock_macho "$STOCK_BACKUP/$rel"; then
        missing="$missing $rel"
    fi
done <<EOF
$STOCK_BINARIES
EOF

if [ -z "$missing" ]; then
    echo "  complete — every stock i386 slice the graft needs is present"
    exit 0
fi

echo "  incomplete (missing:$missing) — checking whether this system still has stock WebKit"
# Capture whole framework bundles, so the nested stock WebCore and the stock Resources come
# along with WebKit.framework. A bundle is captured only when its own binary is stock.
captured=0
for pair in "JavaScriptCore.framework:$JSC_BUNDLE" "WebKit.framework:$WEBKIT_BUNDLE" "WebKit2.framework:$WEBKIT2_BUNDLE"; do
    name="${pair%%:*}"; sys="${pair#*:}"
    binname="$(basename "$name" .framework)"
    if is_stock_macho "$STOCK_BACKUP/$name/Versions/A/$binname"; then
        continue
    fi
    if ! is_stock_macho "$sys/Versions/A/$binname"; then
        echo "" >&2
        echo "ERROR: $sys carries this project's binaries (or no i386 slice), and $STOCK_BACKUP/$name" >&2
        echo "       has no stock copy. The stock 10.9 i386 slices are unrecoverable from this system," >&2
        echo "       and building without them yields x86_64-only frameworks that make every 32-bit" >&2
        echo "       WebView app fail to launch (dyld: no compatible architecture)." >&2
        echo "       Restore the factory frameworks (from a 10.9 installer, a Time Machine snapshot, or" >&2
        echo "       another 10.9 machine) into $STOCK_BACKUP, or point STOCK_BACKUP at a copy that has" >&2
        echo "       them, then rebuild." >&2
        exit 1
    fi
    echo "  capturing stock $name from $sys"
    mkdir -p "$STOCK_BACKUP"
    rm -rf "$STOCK_BACKUP/$name"
    cp -Rp "$sys" "$STOCK_BACKUP/$name"
    captured=1
done

# Re-check: a capture that still leaves a needed slice absent (e.g. a system WebKit.framework
# whose nested WebCore is ours) must not pass silently.
still_missing=""
while IFS= read -r entry; do
    rel="${entry%%:*}"
    is_stock_macho "$STOCK_BACKUP/$rel" || still_missing="$still_missing $rel"
done <<EOF
$STOCK_BINARIES
EOF
if [ -n "$still_missing" ]; then
    echo "ERROR: stock backup is still missing:$still_missing" >&2
    echo "       Every one of these supplies an i386 slice the product needs. Restore them into" >&2
    echo "       $STOCK_BACKUP (see the message above) and rebuild." >&2
    exit 1
fi

if [ "$captured" = 1 ]; then write_manifest; fi
echo "  complete — every stock i386 slice the graft needs is present"
