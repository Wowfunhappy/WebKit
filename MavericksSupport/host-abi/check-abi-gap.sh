#!/bin/bash
# Build gate: every symbol stock Safari 7 binds from our frameworks must be exported by the staged
# product. The contract is safari-needs-from-<framework>.txt (see docs/MAVERICKS-WEBKIT-ABI-REFERENCE.md
# for how it was captured); a non-empty gap fails the build and lists the missing symbols.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/framework-layout.sh"
NM="$CCTOOLS/nm"
rc=0

check() {  # label, staged binary, contract file
    local label="$1" binary="$2" contract="$3" exports need gap
    exports="$(mktemp -t abigap)"
    "$NM" -gU -arch x86_64 "$binary" 2>/dev/null | awk '$2 ~ /^[TSDBR]$/ {print $3}' | sort -u > "$exports"
    need="$(sort -u "$contract")"
    gap="$(comm -23 <(echo "$need") "$exports")"
    printf '  %-16s contract %4d  exported %6d  missing %d\n' "$label" "$(echo "$need" | grep -c .)" "$(wc -l < "$exports")" "$(echo "$gap" | grep -c .)"
    if [ -n "$gap" ]; then
        echo "$gap" | sed 's/^/    MISSING /'
        rc=1
    fi
    rm -f "$exports"
}

check JavaScriptCore "$WK_STAGE_ROOT$JSC_BUNDLE/Versions/A/JavaScriptCore" "$HERE/safari-needs-from-JavaScriptCore.txt"
check WebKit         "$WK_STAGE_ROOT$WEBKIT_BUNDLE/Versions/A/WebKit"     "$HERE/safari-needs-from-WebKit.txt"
check WebKit2        "$WK_STAGE_ROOT$WEBKIT2_BUNDLE/Versions/A/WebKit2"   "$HERE/safari-needs-from-WebKit2.txt"
[ "$rc" = 0 ] && echo "  ok: the staged frameworks export every symbol Safari 7 binds" \
              || echo "ERROR: the staged frameworks are missing symbols Safari 7 binds (above)" >&2
exit $rc
