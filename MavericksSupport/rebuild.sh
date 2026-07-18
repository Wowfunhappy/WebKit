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
# Enable ccache direct mode: WebKit regenerates DerivedSources headers every build with fresh
# timestamps, tripping ccache's too-new guard and forcing the slower preprocessed path on every TU.
# Trusting the include content-hash over mtime/ctime (and ignoring time/PCH-define macros) lets
# direct hits engage, skipping the -E preprocess step.
export CCACHE_SLOPPINESS="include_file_mtime,include_file_ctime,time_macros,pch_defines"

# --- Polyfill (NOT in the ninja graph) -------------------------------------------------------
# MavericksSupport/polyfill/scripts/build-polyfill.sh compiles polyfill/src into the libpolyfill*.a
# archives, which are force-loaded / statically linked into the frameworks via raw -Wl,-force_load
# flags that ninja does NOT track as dependency edges. Without this step, editing a polyfill source
# (e.g. wk_polyfills.m) is SILENTLY ignored by an incremental rebuild — and even after rebuilding the
# archive, ninja won't relink the consuming framework. So: rebuild the polyfill here, then, if an
# archive's CONTENT changed (llvm-ar is deterministic — unchanged source yields identical bytes), rm
# the binaries that consume it so ninja relinks them against the new archive.
#   libpolyfill.a         -> linked into ALL four frameworks (global link_libraries; NO ninja edge — this hash-hack is the only relink trigger)
#   libwk_marker.a        -> force-loaded into ALL four frameworks (WEBKIT_FRAMEWORK; also has a LINK_DEPENDS edge — hash-hack is belt-and-suspenders)
#   libpolyfill_classes.a -> force-loaded into WebCore only (also has a LINK_DEPENDS edge in Source/WebCore/CMakeLists.txt)
#   libwtf_compat.a       -> force-loaded into JavaScriptCore only
POLY_OUT="$ROOT/MavericksSupport/polyfill/build"
poly_hash() { shasum -a 256 "$POLY_OUT/$1" 2>/dev/null | awk '{print $1}'; }
PRE_ALL="$(poly_hash libpolyfill.a)$(poly_hash libwk_marker.a)"   # both span all four frameworks
PRE_WEBCORE="$(poly_hash libpolyfill_classes.a)"
PRE_JSC="$(poly_hash libwtf_compat.a)"
echo "### building polyfill archives (MavericksSupport/polyfill/scripts/build-polyfill.sh)"
if bash "$ROOT/MavericksSupport/polyfill/scripts/build-polyfill.sh" > /tmp/wk_polyfill.log 2>&1; then
    RELINK=""
    [ "$PRE_ALL" != "$(poly_hash libpolyfill.a)$(poly_hash libwk_marker.a)" ] && RELINK="JavaScriptCore WebCore WebKit WebKitLegacy"
    if [ -z "$RELINK" ]; then
        [ "$PRE_WEBCORE" != "$(poly_hash libpolyfill_classes.a)" ] && RELINK="$RELINK WebCore"
        [ "$PRE_JSC" != "$(poly_hash libwtf_compat.a)" ] && RELINK="$RELINK JavaScriptCore"
    fi
    if [ -n "$RELINK" ]; then
        echo "###   polyfill archives changed -> forcing relink:$RELINK"
        for fw in $RELINK; do rm -f "$BUILD/lib/$fw.framework/Versions/A/$fw"; done
    else
        echo "###   polyfill unchanged"
    fi
else
    # ABORT: do NOT fall through to ninja. A failed polyfill build leaves libpolyfill_classes.a stale, so
    # any call site just reverted to a pristine post-10.9 selector (whose wk_ polyfill + __wk_selmap entry
    # exist ONLY in the new archive) would link against the old archive and crash on the un-rewritten public
    # selector at runtime — a silently-broken install. Fail loudly instead.
    echo "==================== POLYFILL BUILD FAILED — ABORTING (would link a STALE polyfill) ===================="
    echo "### see /tmp/wk_polyfill.log:"
    grep -nE "error:|warning:.*wk_|undefined" /tmp/wk_polyfill.log | head -20
    tail -20 /tmp/wk_polyfill.log
    exit 1
fi

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

exit $RC
