#!/bin/bash
# Compute the Safari-7 ABI gap: for each provider framework, which of the
# symbols stock Safari.framework binds against are NOT exported by our built
# framework. A non-empty gap is the exact set that must be polyfilled.
#
# Name shift (10.9 layout -> modern WebKit):
#   JavaScriptCore.framework      <- JavaScriptCore  (contract: 95)
#   /S/L/Frameworks/WebKit        <- WebKitLegacy    (contract: 24)
#   /S/L/PrivateFrameworks/WebKit2 <- WebKit         (contract: 606)
set -u
ABI_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$ABI_DIR/../../WebKitBuild/Release/lib"
NM="${NM:-nm}"

check() {
    local label="$1" binary="$2" contract="$3"
    echo "==================== $label ===================="
    if [ ! -f "$binary" ]; then
        echo "  [skip] binary not built yet: $binary"
        return
    fi
    local exports; exports="$(mktemp -t abigap)"
    # defined external symbols (text/data), strip leading address columns
    "$NM" -gU "$binary" 2>/dev/null | awk '$2 ~ /^[TSDBR]$/ {print $3}' | sort -u > "$exports"
    local need; need="$(sort -u "$contract")"
    local nNeed nHave nGap
    nNeed=$(echo "$need" | grep -c .)
    nHave=$(comm -12 <(echo "$need") "$exports" | grep -c .)
    local gap; gap="$(comm -23 <(echo "$need") "$exports")"
    nGap=$(echo "$gap" | grep -c .)
    echo "  exported by our build: $(wc -l < "$exports")"
    echo "  contract symbols:      $nNeed"
    echo "  satisfied:             $nHave"
    echo "  MISSING (gap):         $nGap"
    if [ "$nGap" -gt 0 ]; then
        echo "  --- missing symbols ---"
        echo "$gap" | sed 's/^/    /'
    fi
    rm -f "$exports"
    echo
}

check "JavaScriptCore"          "$LIB/JavaScriptCore.framework/Versions/Current/JavaScriptCore" "$ABI_DIR/safari-needs-from-JavaScriptCore.txt"
check "WebKit (legacy WebView)" "$LIB/WebKitLegacy.framework/Versions/Current/WebKitLegacy"     "$ABI_DIR/safari-needs-from-WebKit.txt"
check "WebKit2 (WK2)"           "$LIB/WebKit.framework/Versions/Current/WebKit"                 "$ABI_DIR/safari-needs-from-WebKit2.txt"
