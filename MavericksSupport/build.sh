#!/bin/bash
# Build the Mavericks WebKit backport: polyfill archives, ninja (configuring first if the build dir is
# new), staging into WebKitBuild/Release/staged, then the post-build audits. Everything logs to
# /tmp/wk_build.log. "REBUILD DONE (rc=0)" is printed once, at the very end, and is the signal that the
# staged product is complete and installable (sudo bash MavericksSupport/install.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TC="$ROOT/MavericksSupport/toolchain/build"
NINJA="$TC/ninja/bin/ninja"
CMAKE="$TC/cmake/bin/cmake"
CCACHE="${MAVERICKS_CCACHE:-$TC/ccache/bin/ccache}"   # the same resolution as cmake/mac10.9-toolchain.cmake
BUILD="$ROOT/WebKitBuild/Release"
LOG=/tmp/wk_build.log
# The one build log. One fd holds it, so every line lands once and in order, which is what lets the
# FAILED/dups/undefined counts below read it back. Run this bare and tail the log.
exec >> "$LOG" 2>&1

# install.sh installs the staged tree, which survives a failed build. This stamp is the freshness
# signal: cleared here, written back only after a successful link, staging and audit run below.
WK_BUILD_STAMP="$BUILD/staged/.build-complete"
rm -f "$WK_BUILD_STAMP"

# --- What this build links against ------------------------------------------------------------
# deps/build_deps.sh replaces deps/build/{include,lib,bin} wholesale when it finishes, and every
# link below reads from there. It force-loads the polyfill's shared/ sources into the whole media
# runtime as well, so an edit to one of them parts those dylibs from the copy libpolyfill.a gives
# the frameworks; the currency check below the takeover reads only the sources and the deps build's
# manifest, and relinks on a stale answer. The audit at the end proves it over the staged product.
DEPS_LOCK="$ROOT/MavericksSupport/deps/work/.lock"

# --- Take over from an in-flight build --------------------------------------------------------
# One build dir, one log, one build at a time. A running cmake configure is waited out (it rewrites
# build.ninja in place, and a half-written manifest kills every later build); ninja, the polyfill
# compile and staging are interruptible, so they are stopped with SIGTERM, parent first.
_ancestry() { local _p="$1"; while [ "${_p:-0}" -gt 1 ] 2>/dev/null; do echo "$_p"; _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' '); done; }
_family()   { local _c; echo "$1"; for _c in $(pgrep -P "$1" 2>/dev/null); do _family "$_c"; done; }
_is_ours()  { local _a; for _a in $(_ancestry "$1"); do [ "$_a" = "$$" ] && return 0; done
              for _a in $(_ancestry $$); do [ "$_a" = "$1" ] && return 0; done; return 1; }
# Only THIS script counts as a build to take over: the candidate's build.sh argument, resolved against its
# cwd, must be this file (the tree has other build.sh scripts, and so may the machine). This script never
# changes directory, so a running instance's cwd is the one it was launched from.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/build.sh"
_script_of() {
    local _tok _cwd
    _tok=$(ps -o command= -p "$1" 2>/dev/null | tr ' ' '\n' | grep -E '(^|/)build\.sh$' | head -1)
    [ -n "$_tok" ] || return 1
    case "$_tok" in
        /*) ;;
        *)  _cwd=$(lsof -a -d cwd -Fn -p "$1" 2>/dev/null | sed -n 's/^n//p' | head -1); _tok="$_cwd/$_tok";;
    esac
    (cd "$(dirname "$_tok")" 2>/dev/null && echo "$(pwd -P)/$(basename "$_tok")")
}
# Candidates come from ps -axo pid=,command=, which lists every process with its full command line.
# _pids_running takes those whose program is <name>; _pids_running_script those whose command ends in
# a build.sh, which _script_of below holds to this file.
_pids_running() { ps -axo pid=,command= | awk -v n="$1" '{ p = $2; sub(/.*\//, "", p); if (p == n) print $1 }'; }
_pids_running_script() { ps -axo pid=,command= | awk '$0 !~ / -c / && $NF ~ /(^|\/)build\.sh$/ { print $1 }'; }
_stale_builds() {
    local _p
    for _p in $(_pids_running_script); do
        _is_ours "$_p" && continue
        [ "$(_script_of "$_p")" = "$SELF" ] && echo "$_p"
    done
    # A ninja is this build's only when it runs in $BUILD (ninja -C chdirs there); deps/build_deps.sh's
    # meson builds and other trees run their own.
    for _p in $(_pids_running ninja); do
        _is_ours "$_p" && continue
        [ -n "$BUILD_P" ] && [ "$(lsof -a -d cwd -Fn -p "$_p" 2>/dev/null | sed -n 's/^n//p' | head -1)" = "$BUILD_P" ] && echo "$_p"
    done
}
BUILD_P="$(cd "$BUILD" 2>/dev/null && pwd -P)"
# A configure of THIS tree: cmake itself, naming $BUILD. The `cmake -E <tool>` helpers and `-P` install
# steps ninja runs inside build steps are not configures, and other trees' configures (deps/build_deps.sh)
# are not this build's.
_configuring() {
    local _p
    for _p in $(_pids_running cmake); do
        case "$(ps -o command= -p "$_p" 2>/dev/null)" in
            *" -E "*|*" -P "*) ;;
            *"$BUILD"*) return 0;;
            *"$BUILD_P"*) [ -n "$BUILD_P" ] && return 0;;
        esac
    done
    return 1
}
# The lock holder is the build_deps.sh a stale build.sh started; killing it mid-collect leaves
# deps/build torn, so it is waited out instead.
_relinking_deps() {
    local _holder _a _p
    _holder="$(cat "$DEPS_LOCK/pid" 2>/dev/null || true)"
    [ -n "$_holder" ] && kill -0 "$_holder" 2>/dev/null || return 1
    for _a in $(_ancestry "$_holder"); do
        for _p in $1; do [ "$_a" = "$_p" ] && return 0; done
    done
    return 1
}
_waited=0; _tries=0; _stopped=""; _waitedfor=""; TAKEOVER=""
while :; do
    _stale="$(_stale_builds | sort -un)"
    [ -n "$_stale" ] || break
    if [ -z "$_stopped" ]; then
        echo "### a build is already running (pids: $(echo $_stale)) -> stopping it first"
        _stopped="$(echo $_stale)"
    fi
    if _configuring; then
        _waitedfor="cmake configure"
        [ $((_waited % 30)) = 0 ] && echo "###   cmake configure in flight — waiting it out (${_waited}s)"
        sleep 5; _waited=$((_waited + 5)); continue
    fi
    if _relinking_deps "$_stale"; then
        _waitedfor="deps relink"
        [ $((_waited % 30)) = 0 ] && echo "###   its deps relink is in flight — waiting it out (${_waited}s)"
        sleep 5; _waited=$((_waited + 5)); continue
    fi
    for _p in $_stale; do kill $(_family "$_p") 2>/dev/null; done
    _tries=$((_tries + 1))
    if [ "$_tries" -ge 30 ]; then
        echo "==================== COULD NOT STOP THE RUNNING BUILD (pids: $(echo $_stale)) — ABORTING ===================="
        exit 1
    fi
    sleep 2
done
if [ -n "$_stopped" ]; then
    echo "###   in-flight build stopped"
    TAKEOVER="### took over from the build already running (pids: $_stopped)"
    [ "$_waited" -gt 0 ] && TAKEOVER="$TAKEOVER, after waiting ${_waited}s for its $_waitedfor"
fi
: > "$LOG"   # the one truncation of the run; everything below appends
echo "### BUILD RUN $(date -u +%Y-%m-%dT%H:%M:%SZ) pid=$$"
[ -n "$TAKEOVER" ] && echo "$TAKEOVER"

# The relink runs here, after the takeover: it replaces deps/build/{include,lib,bin} wholesale, so
# no other WebKit build may be linking from it. This one has not compiled anything yet, and names
# itself so the deps build does not count it as a link in flight. A deps build no build.sh owns is
# someone running build_deps.sh directly, and this build cannot proceed under it.
DEPS_PID="$(cat "$DEPS_LOCK/pid" 2>/dev/null || true)"
if [ -n "$DEPS_PID" ] && kill -0 "$DEPS_PID" 2>/dev/null; then
    echo "==================== A DEPS BUILD IS RUNNING — ABORTING ===================="
    echo "### $DEPS_LOCK is held by pid $DEPS_PID; rerun when it is done."
    exit 1
fi
# Two axes of deps currency: the gap archive sources the media binaries force-load, and the recipes
# and patches build_deps.sh builds them from. Either one out of date is a run of build_deps.sh.
DEPS_STALE=""
echo "### gap archive currency (MavericksSupport/scripts/check-gap-archive-current.sh --sources-only)"
bash "$ROOT/MavericksSupport/scripts/check-gap-archive-current.sh" --sources-only || DEPS_STALE=1
echo "### deps recipe currency (MavericksSupport/deps/build_deps.sh --check-recipes)"
bash "$ROOT/MavericksSupport/deps/build_deps.sh" --check-recipes || DEPS_STALE=1
if [ -n "$DEPS_STALE" ]; then
    echo "### bringing the deps build up to date (MavericksSupport/deps/build_deps.sh)"
    if ! WK_BUILD_AWAITING_DEPS=$$ bash "$ROOT/MavericksSupport/deps/build_deps.sh"; then
        echo "==================== DEPS BUILD FAILED — ABORTING ===================="
        exit 1
    fi
    if ! bash "$ROOT/MavericksSupport/scripts/check-gap-archive-current.sh" --sources-only; then
        echo "==================== GAP SOURCES ARE AHEAD OF THE DEPS BUILD — ABORTING ===================="
        exit 1
    fi
    if ! bash "$ROOT/MavericksSupport/deps/build_deps.sh" --check-recipes; then
        echo "==================== DEPS RECIPES ARE AHEAD OF THE DEPS BUILD — ABORTING ===================="
        exit 1
    fi
fi

# One ccache for every build of this checkout, and direct mode: WebKit regenerates DerivedSources
# headers with fresh timestamps every build, so trusting include content over mtime is what lets
# direct hits engage. Nothing in a cache key is tied to where the tree sits: CCACHE_BASEDIR names
# the checkout's parent, so every path under it -- the tree itself and the SDK beside it -- is
# hashed relative to the build directory, and the compiler's identity is the content of clang plus
# its two driver configs, hashed once here rather than per translation unit. A cache directory is
# therefore reusable for the same tree at any path and on any machine.
# ccache 3.7 hashes LANG, LC_ALL, LC_CTYPE and LC_MESSAGES. Agent command runners inject
# LC_ALL=C.UTF-8 and LC_CTYPE=C.UTF-8 even when an interactive shell does not, which otherwise
# puts every agent compilation in a distinct cache namespace. Match the canonical interactive
# build environment explicitly so human and agent builds share the existing cache entries.
export LANG=en_US.UTF-8
unset LC_ALL LC_CTYPE LC_MESSAGES
export CCACHE_DIR="$ROOT/WebKitBuild/ccache"
export CCACHE_BASEDIR="$(dirname "$ROOT")"
export CCACHE_NOHASHDIR=1
export CCACHE_SLOPPINESS="include_file_mtime,include_file_ctime,time_macros,pch_defines"
export CCACHE_COMPILERCHECK="string:$(shasum -a 256 \
    "$TC/clang/bin/clang-22" "$TC/clang/bin/clang.cfg" "$TC/clang/bin/clang++.cfg" \
    | awk '{print $1}' | shasum -a 256 | awk '{print $1}')"

# --- Configure (fresh build dir) ---------------------------------------------------------------
# DEVELOPER_MODE is a plain cache variable, not a WebKit option, so every configure passes it:
# WebKitFeatures.cmake forces ENABLE_LAYOUT_TESTS off without it, and it is what selects lld
# (USE_LD_LLD in OptionsCommon.cmake). Warnings stay warnings.
DEV_FLAGS="-DDEVELOPER_MODE=ON -DDEVELOPER_MODE_FATAL_WARNINGS=OFF"
CACHE_FILE="$BUILD/CMakeCache.txt"
if [ ! -f "$CACHE_FILE" ]; then
    echo "### no build dir -> configuring $BUILD"
    if ! "$CMAKE" -S "$ROOT" -B "$BUILD" -G Ninja \
            -DCMAKE_MAKE_PROGRAM="$NINJA" \
            -DCMAKE_TOOLCHAIN_FILE="$ROOT/MavericksSupport/cmake/mac10.9-toolchain.cmake" \
            -DPORT=Mac -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
            -DCMAKE_NINJA_FORCE_RESPONSE_FILE=1 $DEV_FLAGS; then
        echo "==================== CONFIGURE FAILED — ABORTING ===================="
        tail -20 "$LOG"; exit 1
    fi
fi

# --- Re-derive feature options when their defaults change -------------------------------------
# CMake's option() keeps an existing cache entry, so an edited WEBKIT_OPTION_DEFAULT_PORT_VALUE in an
# Options*.cmake is ignored by an incremental configure. When the option files' CONTENT changes (hashed,
# so a mere mtime bump from git does not fire it), every WebKit option's cache entry is unset with
# `cmake -U` and the configure re-applies the port defaults.
OPT_HASH_FILE="$BUILD/.wk-option-defaults.sha256"
_opt_files=$(ls "$ROOT"/Source/cmake/Options*.cmake "$ROOT"/Source/cmake/WebKitFeatures.cmake \
    "$ROOT"/MavericksSupport/cmake/OptionsMac*.cmake 2>/dev/null | sort)
_opt_hash=$(shasum -a 256 $_opt_files 2>/dev/null | shasum -a 256 | awk '{print $1}')
if [ -f "$OPT_HASH_FILE" ] && [ "$_opt_hash" != "$(cat "$OPT_HASH_FILE")" ]; then
    _names=$(grep -rhoE 'WEBKIT_OPTION_(DEFINE|DEFAULT_PORT_VALUE)\([[:space:]]*[A-Z0-9_]+' $_opt_files 2>/dev/null \
        | grep -oE '[A-Z0-9_]+$' | sort -u)
    echo "### option file content changed -> re-deriving $(echo $_names | wc -w | tr -d ' ') feature options from port defaults"
    _uargs=""; for _n in $_names; do _uargs="$_uargs -U $_n"; done
    if ! "$CMAKE" $_uargs $DEV_FLAGS "$BUILD"; then
        echo "==================== RECONFIGURE FAILED — ABORTING ===================="
        tail -20 "$LOG"; exit 1
    fi
fi
[ "$_opt_hash" = "$(cat "$OPT_HASH_FILE" 2>/dev/null)" ] || echo "$_opt_hash" > "$OPT_HASH_FILE"

# --- Polyfill archives (not in the ninja graph) ----------------------------------------------
# The archives are force-loaded through raw -Wl,-force_load flags ninja does not track, so they are
# rebuilt here every time and, when an archive's bytes change (llvm-ar is deterministic), the
# binaries that consume it are removed so ninja relinks them:
#   libpolyfill.a, libwk_marker.a  -> all four frameworks (WEBKIT_FRAMEWORK in WebKitMacros.cmake)
#   libpolyfill_methods.a          -> WebCore          libwtf_compat.a -> JavaScriptCore
#   libpolyfill_webkit.a           -> WebKit
POLY_OUT="$ROOT/MavericksSupport/polyfill/build"
poly_hash() { shasum -a 256 "$POLY_OUT/$1" 2>/dev/null | awk '{print $1}'; }
PRE_ALL="$(poly_hash libpolyfill.a)$(poly_hash libwk_marker.a)"
PRE_WEBCORE="$(poly_hash libpolyfill_methods.a)"
PRE_JSC="$(poly_hash libwtf_compat.a)"
PRE_WEBKIT="$(poly_hash libpolyfill_webkit.a)"
echo "### building polyfill archives (MavericksSupport/polyfill/build-polyfill.sh)"
# $LOG already holds this run's cmake configure output, so the failure path below reads only
# the lines this build appends.
_polyfrom=$(( $(wc -l < "$LOG") + 1 ))
if bash "$ROOT/MavericksSupport/polyfill/build-polyfill.sh"; then
    RELINK=""
    if [ "$PRE_ALL" != "$(poly_hash libpolyfill.a)$(poly_hash libwk_marker.a)" ]; then
        RELINK="JavaScriptCore WebCore WebKit WebKitLegacy"
    else
        [ "$PRE_WEBCORE" != "$(poly_hash libpolyfill_methods.a)" ] && RELINK="$RELINK WebCore"
        [ "$PRE_JSC" != "$(poly_hash libwtf_compat.a)" ] && RELINK="$RELINK JavaScriptCore"
        [ "$PRE_WEBKIT" != "$(poly_hash libpolyfill_webkit.a)" ] && RELINK="$RELINK WebKit"
    fi
    if [ -n "$RELINK" ]; then
        echo "###   polyfill archives changed -> forcing relink:$RELINK"
        for fw in $RELINK; do rm -f "$BUILD/lib/$fw.framework/Versions/A/$fw"; done
    else
        echo "###   polyfill unchanged"
    fi
else
    # A stale archive would link a call site against an old selector map and crash at runtime.
    echo "==================== POLYFILL BUILD FAILED — ABORTING (would link a STALE polyfill) ===================="
    tail -n +$_polyfrom "$LOG" | grep -nE "error:|warning:.*wk_|undefined" | head -20
    tail -20 "$LOG"
    exit 1
fi

# --- Recover an unusable build.ninja ---------------------------------------------------------
# ninja regenerates build.ninja itself (its RERUN_CMAKE rule lists every CMake file), but only if it
# can parse the manifest it has. A configure that wrote an unparsable or truncated manifest leaves
# every later run dead at the same error; heal that with a plain reconfigure.
if [ ! -f "$BUILD/build.ninja" ] || ! "$NINJA" -C "$BUILD" -t targets >/dev/null 2>&1; then
    echo "### build.ninja is missing or does not parse -> reconfiguring to recover"
    if ! "$CMAKE" $DEV_FLAGS "$BUILD"; then
        echo "==================== RECOVERY RECONFIGURE FAILED — ABORTING ===================="
        tail -20 "$LOG"; exit 1
    fi
fi

[ -x "$CCACHE" ] && "$CCACHE" -z >/dev/null   # per-build ccache stats

# The counts below read the log back, and the deps relink and the polyfill build have already
# appended to it. This is where ninja's own output starts; _ninja_log emits exactly that span.
NINJA_LOG_START=$(( $(wc -l < "$LOG") + 1 ))
_ninja_log() { tail -n +"$NINJA_LOG_START" "$LOG"; }

# -k 0: keep going after the first failure so a link stage surfaces ALL undefined symbols at once.
"$NINJA" -C "$BUILD" -k 0 2>&1
RC=$?

echo "==================== COMPILE/LINK PHASE DONE (rc=$RC) — staging still to run ===================="
echo "$(_ninja_log | grep -oE '^\[[0-9]+/[0-9]+\]' | tail -1)  FAILED=$(_ninja_log | grep -c '^FAILED:')"
echo "dups=$(_ninja_log | grep -c 'duplicate symbol')  undefined=$(_ninja_log | grep -c 'undefined symbol')"
echo "--- frameworks built (binary present = linked) ---"
for fw in JavaScriptCore WebCore WebKit WebKitLegacy; do
    [ -e "$BUILD/lib/$fw.framework/$fw" ] && echo "  LINKED  $fw" || echo "  ------  $fw  (no binary)"
done
echo "--- distinct undefined symbols (if any) ---"
_ninja_log | grep 'undefined symbol' | sed -E 's/.*undefined symbol:? *//' | sort -u | head -40
echo "--- distinct error lines ---"
_ninja_log | grep -E 'error:|file not found|FAILED:' | grep -vE 'warning:' | sed -E 's/^[0-9]+\.[0-9]+ //' | sort -u | head -40

# --- Staging + audits -------------------------------------------------------------------------
# stage-frameworks.sh turns the linked frameworks into the complete installable product under
# WebKitBuild/Release/staged; install.sh copies that tree onto the system. The audits need the FINAL
# binaries, which exist only once staging has run:
#   check-absent-references.sh  a reference to a symbol 10.9 lacks binds to 0 and faults on first use
#   check-sandbox-profiles.sh   a profile 10.9's sandbox cannot compile CRASH()es WebContent at launch
#   check-abi-gap.sh            every symbol Safari 7 binds from our frameworks must be exported
#   check-imageio-decode.sh     no shipped binary may construct a CGImageSource: images decode in
#                               WebCore, never in 10.9's ImageIO
if [ "$RC" = 0 ]; then
    echo "==================== STAGING ===================="
    bash "$ROOT/MavericksSupport/scripts/stage-frameworks.sh" || RC=$?

    # The layout-test drivers run the frameworks in $BUILD/lib, not the staged product, and a
    # sandboxed WebContent reaches GStreamer's plugins only through the copy that ships inside
    # WebCore.framework. Mirror the staged copy -- the one whose install names staging has already
    # rewritten -- into the built framework, so a test exercises the same lookup the installed product
    # does and the next run's staging audit sees bundle-relative dependencies.
    GST_PLUGINS_SRC="$BUILD/staged/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/Frameworks/gstreamer/lib/gstreamer-1.0"
    GST_PLUGINS_DST="$BUILD/lib/WebCore.framework/Versions/A/Frameworks/gstreamer/lib/gstreamer-1.0"
    # The libraries beside them are mirrored too: a plugin resolves its own dependencies through
    # @loader_path/../../lib, and the ones WebCore does not itself link -- libgstcodecparsers, which
    # h264parse needs -- are in the process by no other route, so the plugin silently fails to load and
    # the element comes back missing.
    GST_LIBS_SRC="$BUILD/staged/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/Frameworks/gstreamer/lib"
    GST_LIBS_DST="$BUILD/lib/WebCore.framework/Versions/A/Frameworks/gstreamer/lib"
    if [ "$RC" = 0 ] && [ -d "$GST_PLUGINS_SRC" ]; then
        mkdir -p "$GST_PLUGINS_DST"
        rsync -a --delete "$GST_PLUGINS_SRC/" "$GST_PLUGINS_DST/"
        rsync -a --exclude 'gstreamer-1.0/' "$GST_LIBS_SRC/" "$GST_LIBS_DST/"
        echo "  GSTREAMER PLUGINS and libraries mirrored into the built WebCore.framework"
    fi
else
    echo "### staging skipped: the link failed, so there is nothing complete to stage"
fi

for audit in scripts/check-absent-references.sh scripts/check-gap-archive-current.sh scripts/check-imageio-decode.sh sandbox/scripts/check-sandbox-profiles.sh host-abi/check-abi-gap.sh; do
    [ "$RC" = 0 ] || break
    echo "### $audit"
    bash "$ROOT/MavericksSupport/$audit" || RC=$?
done

echo "==================== REBUILD DONE (rc=$RC) ===================="
if [ "$RC" = 0 ]; then
    date +%s > "$WK_BUILD_STAMP"
    echo "### the staged product is complete and installable: sudo bash MavericksSupport/install.sh"
else
    echo "### NOT installable — see the errors above"
fi
exit $RC
