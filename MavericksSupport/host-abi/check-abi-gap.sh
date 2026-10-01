#!/bin/bash
# Build gate: every symbol a 10.9 binary binds from our frameworks must be exported by the staged
# product. Each contract is a list of symbols stock 10.9 exported (see docs/MAVERICKS-WEBKIT-ABI-REFERENCE.md
# for how each was captured):
#   safari-needs-from-<framework>.txt   what stock Safari 7 imports
#   public-needs-from-<framework>.txt   the 10.9 SDK's public API: symbols its WebKit and JavaScriptCore
#                                       headers declare
#   system-needs-from-<framework>.txt   what every other binary on a stock 10.9 system imports
# A symbol counts as exported when the framework or any image it re-exports (recursively, as dyld
# searches them) defines it. A non-empty gap fails the build and lists the missing symbols.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/framework-layout.sh"
NM="$CCTOOLS/nm"
rc=0

# The exports of an installed path and its re-exports, reading the staged twin where the product has one.
closure_exports() {
    local path="$1" file
    file="$WK_STAGE_ROOT$path"
    [ -f "$file" ] || file="$path"
    "$NM" -gU -arch x86_64 "$file" 2>/dev/null | awk '$2 ~ /^[TSDBRIA]$/ {print $3}'
    "$OTOOL" -arch x86_64 -l "$file" 2>/dev/null | awk '/cmd LC_REEXPORT_DYLIB/ {r=1} r && /name/ {print $2; r=0}' |
        while read -r sub; do closure_exports "$sub"; done
}

check() {  # label, installed binary path, contract files...
    local label="$1" binary="$2" exports need gap
    shift 2
    exports="$(mktemp "${TMPDIR:-/tmp}/abigap.XXXXXX")"
    closure_exports "$binary" | sort -u > "$exports"
    need="$(cat "$@" | sort -u)"
    gap="$(comm -23 <(echo "$need") "$exports")"
    printf '  %-16s contract %4d  exported %6d  missing %d\n' "$label" "$(echo "$need" | grep -c .)" "$(wc -l < "$exports")" "$(echo "$gap" | grep -c .)"
    if [ -n "$gap" ]; then
        echo "$gap" | sed 's/^/    MISSING /'
        rc=1
    fi
    rm -f "$exports"
}

contracts() { ls "$HERE"/*-needs-from-"$1".txt; }
check JavaScriptCore "$JSC_BUNDLE/Versions/A/JavaScriptCore" $(contracts JavaScriptCore)
check WebKit         "$WEBKIT_BUNDLE/Versions/A/WebKit"     $(contracts WebKit)
check WebKit2        "$WEBKIT2_BUNDLE/Versions/A/WebKit2"   $(contracts WebKit2)
[ "$rc" = 0 ] && echo "  ok: the staged frameworks export every symbol 10.9 binaries bind" \
              || echo "ERROR: the staged frameworks are missing symbols 10.9 binaries bind (above)" >&2
exit $rc
