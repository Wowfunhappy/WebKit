#!/bin/bash
# Incremental rebuild + link-status report for the Mavericks WebKit backport.
# ninja auto-re-runs cmake when CMakeLists.txt / *.cmake change.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NINJA="$ROOT/MavericksSupport/toolchain/build/ninja/bin/ninja"
CMAKE="$ROOT/MavericksSupport/toolchain/build/cmake/bin/cmake"
[ -x "$CMAKE" ] || CMAKE="$ROOT/Compilers/toolchains/cmake-new/bin/cmake"
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

# --- Re-derive feature options when their defaults change -------------------------------------
# CMake's option() HONORS an existing cache entry, so editing a WEBKIT_OPTION_DEFAULT_PORT_VALUE
# default in Source/cmake/Options*.cmake is SILENTLY IGNORED on an incremental build: ninja re-runs
# cmake, but option() keeps whatever value is already in CMakeCache.txt from the first configure.
# (This is exactly why flipping ENABLE_GAMEPAD ON in OptionsMac.cmake left it compiled OUT.) When an
# option-defining file has changed, drop every WebKit option's cache entry and reconfigure so the
# edited port defaults actually take effect. Only fires when such a file is edited — normal
# incremental builds skip it entirely. A deliberate `-D<OPT>=` override is re-derived from the source
# default too; for this port the feature config lives in Options*.cmake, not in ad-hoc -D flags.
CACHE_FILE="$BUILD/CMakeCache.txt"
# Gate on the option files' CONTENT, not their mtime. The old test (`Options*.cmake -nt CMakeCache.txt`)
# fired a full `cmake -U <~200 opts> $BUILD` reconfigure (~1-3 min, plus it regenerates the 48 MB
# build.ninja) whenever an option file's mtime was merely bumped — which, in this repo's revert-heavy
# git workflow, happens constantly WITHOUT any net content change (git checkout / revert / stash all
# rewrite files to `now`; so does re-saving in an editor). That is a pure waste: the re-derived option
# values are byte-identical, so the reconfigure changes nothing. Hashing the option files instead makes
# the re-derive fire exactly when their bytes change, and never on a spurious touch. Marking on CONTENT
# is also strictly more correct than mtime: it can't be fooled by clock skew or an out-of-order touch.
OPT_HASH_FILE="$BUILD/.wk-option-defaults.sha256"
if [ -f "$CACHE_FILE" ]; then
    # Hash the per-file digests (captures both the file set and every file's contents).
    _opt_files=$(ls "$ROOT"/Source/cmake/Options*.cmake "$ROOT"/Source/cmake/WebKitFeatures.cmake 2>/dev/null | sort)
    _opt_hash=$(shasum -a 256 $_opt_files 2>/dev/null | shasum -a 256 | awk '{print $1}')
    _fire=""
    if [ -f "$OPT_HASH_FILE" ]; then
        # Steady state: fire only when the option files' CONTENT differs from what we last re-derived.
        [ "$_opt_hash" != "$(cat "$OPT_HASH_FILE" 2>/dev/null)" ] && _fire=1
    else
        # Transition build (no marker yet): fall back to the original mtime test so behaviour is
        # byte-identical this once (fires iff an option file is newer than CMakeCache — which a normal
        # incremental build is NOT), then seed the marker below. Avoids a spurious one-time reconfigure.
        for _f in $_opt_files; do [ "$_f" -nt "$CACHE_FILE" ] && _fire=1; done
    fi
    if [ -n "$_fire" ]; then
        _names=$(grep -rhoE 'WEBKIT_OPTION_(DEFINE|DEFAULT_PORT_VALUE)\([[:space:]]*[A-Z0-9_]+' \
            "$ROOT"/Source/cmake/WebKitFeatures.cmake "$ROOT"/Source/cmake/Options*.cmake 2>/dev/null \
            | grep -oE '[A-Z0-9_]+$' | sort -u)
        if [ -n "$_names" ]; then
            echo "### option file content changed -> re-deriving $(echo $_names | wc -w | tr -d ' ') feature options from port defaults"
            # `cmake -U` unsets each option's cache entry (value AND its //helpstring) so the next
            # configure re-applies the WEBKIT_OPTION_DEFAULT_PORT_VALUE default; everything else in the
            # cache (toolchain, generator, paths) is preserved, so no configure flags need re-passing.
            _uargs=""
            for _n in $_names; do _uargs="$_uargs -U $_n"; done
            if ! "$CMAKE" $_uargs "$BUILD" >> "$LOG" 2>&1; then
                echo "==================== RECONFIGURE FAILED — ABORTING ===================="
                tail -20 "$LOG"; exit 1
            fi
        fi
    fi
    # Persist the content hash so the next build compares against it. Reached only on success (a failed
    # reconfigure exits above, so it retries next time). Also seeds the marker on the first post-fix
    # build. Guarded so we write at most once per actual content change, never on a plain rebuild.
    if [ "$_opt_hash" != "$(cat "$OPT_HASH_FILE" 2>/dev/null)" ]; then
        echo "$_opt_hash" > "$OPT_HASH_FILE"
    fi
fi

# --- Polyfill (NOT in the ninja graph) -------------------------------------------------------
# MavericksSupport/polyfill/scripts/build-polyfill.sh compiles polyfill/src into the libpolyfill*.a
# archives, which are force-loaded / statically linked into the frameworks via raw -Wl,-force_load
# flags that ninja does NOT track as dependency edges. Without this step, editing a polyfill source
# (e.g. wk_polyfills.m) is SILENTLY ignored by an incremental rebuild — and even after rebuilding the
# archive, ninja won't relink the consuming framework. So: rebuild the polyfill here, then, if an
# archive's CONTENT changed (llvm-ar is deterministic — unchanged source yields identical bytes), rm
# the binaries that consume it so ninja relinks them against the new archive.
#   libpolyfill.a         -> force-loaded into every shipped binary: the four frameworks (WEBKIT_FRAMEWORK) and the WebProcess/NetworkProcess/GPUProcess executables (explicit _WEBKIT_FORCE_LOAD_POLYFILL calls in Source/WebKit/CMakeLists.txt). Build-time tools get it as a plain archive instead (link_libraries in OptionsMac.cmake). Also has a LINK_DEPENDS edge — hash-hack is belt-and-suspenders
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

# --- Recover a wedged build.ninja ------------------------------------------------------------
# ninja normally regenerates build.ninja itself: the RERUN_CMAKE rule lists every CMakeLists/*.cmake
# as a dependency — INCLUDING the MavericksSupport overlays (WebCore/WebKitPlatformMavericks.cmake) —
# so a plain edit to any of them is picked up automatically on the next build. But that self-reconfigure
# rule lives INSIDE build.ninja. If a configure ever writes a manifest ninja can't parse (e.g. a
# duplicate build output — "ninja: error: build.ninja:N: ... defined as an output multiple times"),
# ninja can no longer load the manifest to reach RERUN_CMAKE, so it is wedged: every subsequent run
# dies at the identical parse error even after the offending .cmake is fixed, until someone runs
# `cmake $BUILD` by hand. Detect the unparseable manifest with a cheap read-only load and heal it with
# a plain reconfigure. No -U here: this is manifest recovery, not an option-default change (the feature
# re-derive above owns that, and -U would needlessly reset every option).
if [ -f build.ninja ] && ! "$NINJA" -t targets >/dev/null 2>&1; then
    echo "### build.ninja does not parse (a prior configure wrote a bad manifest) -> reconfiguring to recover"
    if ! "$CMAKE" "$BUILD" >> "$LOG" 2>&1; then
        echo "==================== RECOVERY RECONFIGURE FAILED — ABORTING ===================="
        tail -20 "$LOG"; exit 1
    fi
fi

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

# --- Staging: the last phase of the build ----------------------------------------------------
# ninja links the frameworks; stage-frameworks.sh turns them into the complete, installable
# product under WebKitBuild/Release/staged (name shift, bundle resources, in-bundle runtime +
# GStreamer, absolute install names, demangler guard, full XPC service set, stock i386 slices).
# install-safari7.sh then just copies that tree onto the system.
if [ "$RC" = 0 ]; then
    echo "==================== STAGING ===================="
    bash "$ROOT/MavericksSupport/scripts/stage-frameworks.sh" || RC=$?
else
    echo "### staging skipped: the link failed, so there is nothing complete to stage"
fi

exit $RC
