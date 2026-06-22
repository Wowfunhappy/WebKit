#!/bin/bash
# Incremental rebuild + link-status report for the Mavericks WebKit backport.
# ninja auto-re-runs cmake when CMakeLists.txt / *.cmake change.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NINJA="$ROOT/MavericksSupport/toolchain/build/ninja/bin/ninja"
BUILD="$ROOT/WebKitBuild/Release"
LOG=/tmp/wk_build.log
# Pin ccache to the in-tree cache so incremental builds share one cache regardless of the caller's
# environment (without this, ccache falls back to ~/.ccache and the cache is split / cold).
export CCACHE_DIR="$ROOT/WebKitBuild/ccache"

cd "$BUILD"
# -k 0 : keep going after the first failure so a link stage surfaces ALL undefined symbols at once.
"$NINJA" -k 0 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}

echo "==================== REBUILD DONE (rc=$RC) ===================="
prog=$(grep -oE '^\[[0-9]+/[0-9]+\]' "$LOG" | tail -1)
fails=$(grep -c '^FAILED:' "$LOG")
echo "$prog  FAILED=$fails"
echo "dups=$(grep -c 'duplicate symbol' "$LOG")  undefined=$(grep -c 'undefined symbol' "$LOG")  gstnotfound=$(grep -c "'gst/gst.h' file not found" "$LOG")"

echo "--- frameworks/dylibs built (binary present = linked) ---"
for fw in JavaScriptCore WebCore WebKit WebKitLegacy; do
    b="$BUILD/lib/$fw.framework/$fw"
    [ -e "$b" ] && echo "  LINKED  $fw" || echo "  ------  $fw  (no binary)"
done

echo "--- distinct undefined symbols (if any) ---"
grep 'undefined symbol' "$LOG" | sed -E 's/.*undefined symbol:? *//' | sort -u | head -40

echo "--- distinct error lines ---"
grep -E 'error:|file not found|FAILED:' "$LOG" | grep -vE 'warning:' | sed -E 's/^[0-9]+\.[0-9]+ //' | sort -u | head -40

echo "--- failed targets ---"
grep -A1 '^FAILED:' "$LOG" | grep -oE '[A-Za-z0-9_]+\.framework|WebKitLegacy|WebCore|JavaScriptCore|WebKit' | sort -u | head
